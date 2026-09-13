defmodule OCEx.ExtrusionTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  defp face(w \\ 20, h \\ 16), do: ok(OCEx.face(rectangle(w, h)))

  defp ring do
    body = ok(OCEx.cut(ok(OCEx.cylinder(10, 2)), ok(OCEx.cylinder(4, 2))))
    ok(OCEx.section(body, {0, 0, 0}, {0, 0, 1}))
  end

  test "symmetric extrusion spans both vector directions and preserves the source" do
    profile = face(4, 6)
    before = ok(OCEx.to_brep(profile))

    for v <- [{1, 0, 3}, {-1, 0, -3}] do
      body = ok(OCEx.extrude(profile, v, both: true))
      assert_valid(body)
      assert length(ok(OCEx.solids(body))) == 1
      assert length(ok(OCEx.faces(body))) == 6
      assert_in_delta volume(body), 144, 1.0e-6
      {low, high} = ok(OCEx.bounds(body))
      close_point(low, {-1, 0, -3})
      close_point(high, {5, 6, 3})
    end

    assert ok(OCEx.to_brep(profile)) == before
  end

  test "signed taper has analytic rectangular sections in either extrusion direction" do
    profile = face()
    before = ok(OCEx.to_brep(profile))

    for angle <- [-5, 5], sign <- [-1, 1] do
      slope = :math.tan(angle * :math.pi() / 180)
      body = ok(OCEx.extrude(profile, {0, 0, sign * 10}, taper: angle))
      assert_valid(body)
      assert length(ok(OCEx.solids(body))) == 1
      expected = 320 * 10 - 36 * slope * 100 + 4 * slope * slope * 1000 / 3
      assert_in_delta volume(body), expected, 1.0e-5
      cap = ok(OCEx.section(body, {0, 0, sign * 10}, {0, 0, 1}))
      assert_in_delta ok(OCEx.area(cap)), (20 - 20 * slope) * (16 - 20 * slope), 1.0e-5
    end

    assert ok(OCEx.to_brep(profile)) == before
  end

  test "taper changes both walls of holes and symmetric halves join as one solid" do
    profile = ring()

    for both <- [false, true], angle <- [-4, 4], sign <- [-1, 1] do
      slope = :math.tan(angle * :math.pi() / 180)
      body = ok(OCEx.extrude(profile, {0, 0, sign * 5}, taper: angle, both: both))
      expected = :math.pi() * (84 * 5 - 14 * slope * 25) * if(both, do: 2, else: 1)
      assert_in_delta volume(body), expected, 1.0e-5
      assert length(ok(OCEx.solids(body))) == 1
      cap = ok(OCEx.section(body, {0, 0, sign * 5}, {0, 0, 1}))
      assert length(ok(OCEx.wires(cap))) == 2

      assert_in_delta ok(OCEx.area(cap)),
                      :math.pi() * ((10 - 5 * slope) ** 2 - (4 + 5 * slope) ** 2),
                      1.0e-5
    end
  end

  test "taper is invariant under rigid placement and disconnected faces stay separate" do
    profile = face()
    base = ok(OCEx.extrude(profile, {0, 0, 4}, taper: 3, both: true))
    rotated = ok(OCEx.rotate(profile, {0, 0, 0}, {0, 1, 0}, 90))
    placed = ok(OCEx.translate(rotated, {10, 20, 30}))
    actual = ok(OCEx.extrude(placed, {4, 0, 0}, taper: 3, both: true))

    expected =
      base
      |> OCEx.rotate({0, 0, 0}, {0, 1, 0}, 90)
      |> ok()
      |> OCEx.translate({10, 20, 30})
      |> ok()

    assert_in_delta volume(ok(OCEx.cut(actual, expected))), 0, 1.0e-6
    assert_in_delta volume(ok(OCEx.cut(expected, actual))), 0, 1.0e-6
    profiles = ok(OCEx.compound([profile, ok(OCEx.translate(profile, {40, 0, 0}))]))
    pair = ok(OCEx.extrude(profiles, {0, 0, 4}, taper: 3, both: true))
    assert length(ok(OCEx.solids(pair))) == 2
    assert_in_delta volume(pair), 2 * volume(base), 1.0e-5
  end

  test "default options preserve the existing prism geometry" do
    profile = face()
    existing = ok(OCEx.extrude(profile, {1, 2, 3}))
    explicit = ok(OCEx.extrude(profile, {1, 2, 3}, both: false, taper: 0))
    assert ok(OCEx.to_brep(existing)) == ok(OCEx.to_brep(explicit))
  end

  test "invalid taper and option combinations fail without changing the profile" do
    profile = face()
    before = ok(OCEx.to_brep(profile))

    for opts <- [[both: :yes], [taper: :bad], [taper: 1, taper: 2], [unknown: 1], nil] do
      assert {:error, :invalid_options} = OCEx.extrude(profile, {0, 0, 5}, opts)
    end

    for angle <- [-90, 90, 100] do
      assert {:error, :invalid_argument} = OCEx.extrude(profile, {0, 0, 5}, taper: angle)
    end

    assert {:error, :invalid_taper_direction} = OCEx.extrude(profile, {1, 0, 5}, taper: 5)
    assert {:error, _} = OCEx.extrude(profile, {0, 0, 100}, taper: 45)

    assert {:error, :wrong_shape_type} =
             OCEx.extrude(ok(OCEx.box(2, 2, 2)), {0, 0, 5}, both: true)

    assert ok(OCEx.to_brep(profile)) == before
  end

  test "extrusion until a tilted plane has the expected cap and volume" do
    profile = face(10, 6)
    before = ok(OCEx.to_brep(profile))
    # z = 4 + x / 2, with average height 6.5 over the rectangle.
    for normal <- [{-0.5, 0, 1}, {0.5, 0, -1}] do
      body = ok(OCEx.extrude_until(profile, {0, 0, 7}, {0, 0, 4}, normal))
      assert_valid(body)
      assert_in_delta volume(body), 390, 1.0e-6
      {low, high} = ok(OCEx.bounds(body))
      close_point(low, {0, 0, 0})
      close_point(high, {10, 6, 9})
      cap = ok(OCEx.section(body, {0, 0, 4}, normal))
      assert_in_delta ok(OCEx.area(cap)), 60 * :math.sqrt(1.25), 1.0e-6
    end

    assert ok(OCEx.to_brep(profile)) == before
  end

  test "until supports oblique travel, negative travel, holes and disconnected faces" do
    for {profile, direction, origin, normal, expected} <- [
          {face(4, 6), {1, 0, 2}, {0, 0, 8}, {0, 0, 1}, 192},
          {face(4, 6), {0, 0, -1}, {0, 0, -8}, {0, 0, 1}, 192},
          {ring(), {0, 0, 1}, {0, 0, 5}, {0, 0, 1}, 420 * :math.pi()}
        ] do
      body = ok(OCEx.extrude_until(profile, direction, origin, normal))
      assert_in_delta volume(body), expected, 1.0e-5
    end

    a = face(2, 3)
    profiles = ok(OCEx.compound([a, ok(OCEx.translate(a, {10, 0, 0}))]))
    body = ok(OCEx.extrude_until(profiles, {0, 0, 1}, {0, 0, 5}, {0, 0, 1}))
    assert length(ok(OCEx.solids(body))) == 2
    assert_in_delta volume(body), 60, 1.0e-6
  end

  test "until rejects parallel, behind, touching or crossing target planes" do
    profile = face(10, 6)

    assert {:error, :invalid_direction} =
             OCEx.extrude_until(profile, {0, 0, 1}, {1, 0, 0}, {1, 0, 0})

    for {origin, normal} <- [
          {{0, 0, -1}, {0, 0, 1}},
          {{0, 0, 0}, {0, 0, 1}},
          {{0, 0, 2}, {1, 0, 1}}
        ] do
      assert {:error, :target_not_ahead} = OCEx.extrude_until(profile, {0, 0, 1}, origin, normal)
    end

    assert {:error, :invalid_argument} =
             OCEx.extrude_until(profile, {0, 0, 0}, {0, 0, 5}, {0, 0, 1})

    assert {:error, :degenerate_extrusion} =
             OCEx.extrude_until(profile, {1, 0, 0}, {10, 0, 0}, {1, 0, 0})
  end

  test "until follows arbitrary rigid placement without relying on world bounding boxes" do
    profile = face(10, 6)
    body = ok(OCEx.extrude_until(profile, {0, 0, 1}, {0, 0, 4}, {-0.5, 0, 1}))

    place = fn shape ->
      shape
      |> OCEx.rotate({0, 0, 0}, {0, 1, 0}, 90)
      |> ok()
      |> OCEx.translate({100, -50, 30})
      |> ok()
    end

    actual = ok(OCEx.extrude_until(place.(profile), {1, 0, 0}, {104, -50, 30}, {1, 0, 0.5}))
    expected = place.(body)
    assert_in_delta volume(ok(OCEx.cut(actual, expected))), 0, 1.0e-6
    assert_in_delta volume(ok(OCEx.cut(expected, actual))), 0, 1.0e-6
  end
end
