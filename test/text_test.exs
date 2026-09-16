defmodule OCEx.TextTest do
  use ExUnit.Case, async: true

  @ttf File.read!(Path.join(__DIR__, "fixtures/fonts/Graduate-Regular.ttf"))
  @otf File.read!(Path.join(__DIR__, "fixtures/fonts/SourceSans3-Regular.otf"))
  @curved File.read!(Path.join(__DIR__, "fixtures/fonts/Abel-Regular.ttf"))

  test "font outlines retain counters and disconnected components and extrude analytically" do
    for {font, components} <- [{@ttf, 3}, {@otf, 4}, {@curved, 4}] do
      assert {:ok, text} = OCEx.text("BOi", font, 10)
      assert {:ok, true} = OCEx.valid?(text.shape)
      assert {:ok, faces} = OCEx.faces(text.shape)
      assert length(faces) == components
      assert {:ok, area} = OCEx.area(text.shape)
      assert area > 0
      assert {:ok, solid} = OCEx.extrude(text.shape, {0, 0, 2})
      assert {:ok, volume} = OCEx.volume(solid)
      assert_in_delta volume, area * 2, 1.0e-5
      assert {:ok, solids} = OCEx.solids(solid)
      assert length(solids) == components
      assert {:ok, wires} = OCEx.wires(text.shape)
      assert length(wires) == components + 3
      assert length(text.glyphs) == 3
      assert text.units_per_em > 0
    end
  end

  test "the middle of O remains empty after extrusion" do
    assert {:ok, text} = OCEx.text("O", @otf, 10)
    assert {:ok, {{x0, y0, _}, {x1, y1, _}}} = OCEx.bounds(text.shape)
    assert {:ok, body} = OCEx.extrude(text.shape, {0, 0, 2})
    assert {:ok, probe} = OCEx.cylinder(0.05, 2)
    assert {:ok, probe} = OCEx.translate(probe, {(x0 + x1) / 2, (y0 + y1) / 2, 0})
    assert {:ok, common} = OCEx.common(body, probe)
    assert {:ok, volume} = OCEx.volume(common)
    assert abs(volume) < 1.0e-8
  end

  test "size scales real outline area and advances; whitespace changes advance only" do
    assert {:ok, small} = OCEx.text("AVA", @otf, 10)
    assert {:ok, large} = OCEx.text("AVA", @otf, 20)
    assert {:ok, spaced} = OCEx.text(" AVA ", @otf, 10)
    assert {:ok, a} = OCEx.area(small.shape)
    assert {:ok, b} = OCEx.area(large.shape)
    assert {:ok, c} = OCEx.area(spaced.shape)
    assert_in_delta b, a * 4, 1.0e-5
    assert_in_delta a, c, 1.0e-5
    assert_in_delta large.advance, small.advance * 2, 1.0e-8
    assert spaced.advance > small.advance
    assert {:ok, tracked} = OCEx.text("AVA", @otf, 10, tracking: 1)
    assert_in_delta tracked.advance, small.advance + 2, 1.0e-8
  end

  test "kerning, ligatures and accented text use shaped font glyphs" do
    assert {:ok, av} = OCEx.text("AV", @otf, 10)
    assert {:ok, a} = OCEx.text("A", @otf, 10)
    assert {:ok, v} = OCEx.text("V", @otf, 10)
    assert av.advance < a.advance + v.advance
    assert {:ok, ligature} = OCEx.text("ffi", @otf, 10)
    assert length(ligature.glyphs) < 3
    assert {:ok, accented} = OCEx.text("Zoë", @otf, 10)
    assert {:ok, true} = OCEx.valid?(accented.shape)
    assert Enum.all?(accented.glyphs, &(&1.glyph_id > 0))
  end

  test "missing glyphs, empty ink, malformed fonts and invalid options fail explicitly" do
    assert {:error, :missing_glyph} = OCEx.text("\u{10FFFF}", @ttf, 10)
    assert {:error, :empty_text} = OCEx.text("   ", @ttf, 10)
    assert {:error, :invalid_font} = OCEx.text("A", "not a font", 10)

    for value <- ["", "A\nB", <<255>>, "A\0B"] do
      assert {:error, :invalid_text} = OCEx.text(value, @ttf, 10)
    end

    assert {:error, :invalid_argument} = OCEx.text("A", @ttf, 0)
    assert {:error, :invalid_options} = OCEx.text("A", @ttf, 10, size: 2)
    assert {:error, :invalid_options} = OCEx.text("A", @ttf, 10, tracking: 0, tracking: 1)
  end

  test "explicit RTL and composed accents preserve shaped cluster semantics" do
    assert {:ok, rtl} = OCEx.text("AB", @otf, 10, direction: :rtl)
    assert rtl.direction == "rtl"
    assert Enum.map(rtl.glyphs, & &1.cluster) == [1, 0]
    assert {:ok, a} = OCEx.text("é", @otf, 10)
    assert {:ok, b} = OCEx.text("e\u0301", @otf, 10)
    assert {:ok, area_a} = OCEx.area(a.shape)
    assert {:ok, area_b} = OCEx.area(b.shape)
    assert_in_delta area_a, area_b, 1.0e-7
    assert Enum.map(a.glyphs, & &1.glyph_id) == Enum.map(b.glyphs, & &1.glyph_id)
  end

  test "overlapping glyphs are unioned and input shapes survive later font calls" do
    {:ok, single} = OCEx.text("O", @curved, 10)
    {:ok, overlap} = OCEx.text("OO", @curved, 10, tracking: -single.advance / 2)
    {:ok, a} = OCEx.area(single.shape)
    {:ok, b} = OCEx.area(overlap.shape)
    assert b > a and b < 2 * a
    {:ok, body} = OCEx.extrude(overlap.shape, {0, 0, 2})
    {:ok, volume} = OCEx.volume(body)
    assert_in_delta volume, b * 2, 1.0e-5
    {:ok, brep} = OCEx.to_brep(single.shape)
    OCEx.text("ANOTHER FONT", @otf, 4)
    assert {:ok, ^brep} = OCEx.to_brep(single.shape)
  end

  test "font metadata and raw native errors are bounded" do
    assert {:ok, %{family: "Graduate", units_per_em: 1000}} = OCEx.font_info(@ttf)
    assert {:error, :invalid_font} = OCEx.font_info(@ttf, 1000)
    assert {:error, :invalid_argument} = OCEx.font_info(@ttf, -1)

    for value <- [nil, [], 5, make_ref()] do
      assert {:error, _} = OCEx.Native.call(:font_info, [value, 0])
      assert {:error, _} = OCEx.Native.call(:text, ["A", value, 10, 0, 0, "auto", ""])
    end
  end
end
