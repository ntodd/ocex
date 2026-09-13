defmodule OCEx.PartitionTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  test "split retains either signed half or all separate solids without changing the source" do
    body = ok(OCEx.box(20, 12, 10))
    before = ok(OCEx.to_brep(body))

    for {keep, expected, count} <- [{:positive, 1680, 1}, {:negative, 720, 1}, {:both, 2400, 2}] do
      part = ok(OCEx.split(body, {0, 0, 3}, {0, 0, 2}, keep: keep))
      assert_valid(part)
      assert_in_delta volume(part), expected, 1.0e-6
      assert length(ok(OCEx.solids(part))) == count
    end

    assert ok(OCEx.to_brep(body)) == before
    assert length(ok(OCEx.solids(ok(OCEx.split(body, {0, 0, 3}, {0, 0, 1}))))) == 2
    reversed = ok(OCEx.split(body, {0, 0, 3}, {0, 0, -1}, keep: :positive))
    assert_in_delta volume(reversed), 720, 1.0e-6
  end

  test "oblique halves preserve material and have no volume overlap" do
    body = ok(OCEx.box(10, 10, 10))
    positive = ok(OCEx.split(body, {0, 0, 0}, {1, -1, 0}, keep: :positive))
    negative = ok(OCEx.split(body, {0, 0, 0}, {1, -1, 0}, keep: :negative))
    assert_in_delta volume(positive), 500, 1.0e-6
    assert_in_delta volume(negative), 500, 1.0e-6
    assert_in_delta volume(ok(OCEx.common(positive, negative))), 0, 1.0e-7
    restored = ok(OCEx.fuse(positive, negative))
    assert_in_delta volume(ok(OCEx.cut(body, restored))), 0, 1.0e-7
    assert_in_delta volume(ok(OCEx.cut(restored, body))), 0, 1.0e-7
  end

  test "outside and tangent split planes retain material or return an empty compound" do
    body = ok(OCEx.box(10, 10, 10))

    for z <- [10, 20] do
      empty = ok(OCEx.split(body, {0, 0, z}, {0, 0, 1}, keep: :positive))
      assert ok(OCEx.solids(empty)) == []
      assert ok(OCEx.faces(empty)) == []

      assert_in_delta volume(ok(OCEx.split(body, {0, 0, z}, {0, 0, 1}, keep: :negative))),
                      1000,
                      1.0e-6

      assert_in_delta volume(ok(OCEx.split(body, {0, 0, z}, {0, 0, 1}))), 1000, 1.0e-6
    end
  end

  test "section retains a ring's inner boundary and follows the supplied plane normal" do
    ring = ok(OCEx.cut(ok(OCEx.cylinder(5, 10)), ok(OCEx.cylinder(2, 10))))
    before = ok(OCEx.to_brep(ring))

    for normal <- [{0, 0, 1}, {0, 0, -2}] do
      section = ok(OCEx.section(ring, {0, 0, 4}, normal))
      assert_valid(section)
      assert {:ok, :face} = OCEx.shape_type(section)
      assert_in_delta ok(OCEx.area(section)), 21 * :math.pi(), 1.0e-6
      assert length(ok(OCEx.wires(section))) == 2
      info = ok(OCEx.face_info(section))
      assert elem(info.normal, 2) * elem(normal, 2) > 0
      extruded = ok(OCEx.extrude(section, {0, 0, 3}))
      assert_in_delta volume(extruded), 63 * :math.pi(), 1.0e-6
    end

    assert ok(OCEx.to_brep(ring)) == before
  end

  test "oblique section yields the exact diagonal rectangle" do
    body = ok(OCEx.box(10, 10, 10))
    section = ok(OCEx.section(body, {0, 0, 0}, {1, -1, 0}))
    assert_in_delta ok(OCEx.area(section)), 100 * :math.sqrt(2), 1.0e-6
    assert length(ok(OCEx.edges(section))) == 4
  end

  test "disconnected sections remain faces that can be extruded together" do
    a = ok(OCEx.box(4, 5, 6))
    b = ok(OCEx.translate(a, {10, 0, 0}))
    body = ok(OCEx.compound([a, b]))
    section = ok(OCEx.section(body, {0, 0, 3}, {0, 0, 1}))
    assert {:ok, :compound} = OCEx.shape_type(section)
    assert length(ok(OCEx.faces(section))) == 2
    assert_in_delta ok(OCEx.area(section)), 40, 1.0e-6
    extrusion = ok(OCEx.extrude(section, {1, 0, 2}))
    assert length(ok(OCEx.solids(extrusion))) == 2
    assert_in_delta volume(extrusion), 80, 1.0e-6
    split = ok(OCEx.split(body, {0, 0, 3}, {0, 0, 1}))
    assert length(ok(OCEx.solids(split))) == 4
  end

  test "empty sections omit tangent edges but retain coplanar material faces" do
    body = ok(OCEx.box(10, 10, 10))
    outside = ok(OCEx.section(body, {0, 0, 20}, {0, 0, 1}))
    assert ok(OCEx.faces(outside)) == []
    assert_in_delta ok(OCEx.area(ok(OCEx.section(body, {0, 0, 10}, {0, 0, 1})))), 100, 1.0e-6
    sphere = ok(OCEx.sphere(5))
    section = ok(OCEx.section(sphere, {0, 0, 5}, {0, 0, 1}))
    assert ok(OCEx.faces(section)) == []
    assert ok(OCEx.edges(section)) == []
  end

  test "partition and multi-face extrusion reject unsupported topology and invalid options" do
    body = ok(OCEx.box(10, 10, 10))
    face = hd(ok(OCEx.faces(body)))
    edge = hd(ok(OCEx.edges(body)))

    for op <- [:split, :section] do
      assert {:error, :invalid_argument} = apply(OCEx, op, [body, {0, 0, 0}, {0, 0, 0}])
      assert {:error, :wrong_shape_type} = apply(OCEx, op, [face, {0, 0, 0}, {0, 0, 1}])
      mixed = ok(OCEx.compound([body, edge]))
      assert {:error, :wrong_shape_type} = apply(OCEx, op, [mixed, {0, 0, 0}, {0, 0, 1}])
    end

    for opts <- [[keep: :top], [keep: :both, keep: :positive], [unknown: true], nil] do
      assert {:error, :invalid_options} = OCEx.split(body, {0, 0, 5}, {0, 0, 1}, opts)
    end

    assert {:error, :wrong_shape_type} = OCEx.extrude(ok(OCEx.compound([face, edge])), {1, 1, 1})
    assert {:error, :wrong_shape_type} = OCEx.extrude(ok(OCEx.compound([])), {0, 0, 1})
  end
end
