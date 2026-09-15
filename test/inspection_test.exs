defmodule OCEx.InspectionTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  test "closest points measure clearance and detect intersecting or contained solids" do
    a = ok(OCEx.box(10, 10, 10))
    b = ok(OCEx.translate(a, {13, 0, 0}))
    before = ok(OCEx.to_brep(a))

    assert {:ok, %{distance: distance, point_a: {ax, ay, az}, point_b: {bx, by, bz}}} =
             OCEx.closest_points(a, b)

    assert_in_delta distance, 3, 1.0e-7
    assert_in_delta bx - ax, 3, 1.0e-7
    assert_in_delta ay, by, 1.0e-7
    assert_in_delta az, bz, 1.0e-7

    for other <- [a, ok(OCEx.box(2, 2, 2)), ok(OCEx.translate(a, {5, 0, 0}))] do
      assert {:ok, %{distance: d}} = OCEx.closest_points(a, other)
      assert_in_delta d, 0, 1.0e-7
    end

    assert before == ok(OCEx.to_brep(a))
    assert {:error, :empty_shape} = OCEx.closest_points(a, ok(OCEx.compound([])))
  end

  test "circular edge metadata exposes its actual center and axis" do
    circle = ok(OCEx.circle(3)) |> then(&ok(OCEx.translate(&1, {4, 5, 6})))

    assert {:ok, %{center: {4.0, 5.0, 6.0}, axis: {x, y, z}, radius: 3.0}} =
             OCEx.edge_info(circle)

    assert_in_delta x, 0, 1.0e-7
    assert_in_delta y, 0, 1.0e-7
    assert_in_delta z, 1, 1.0e-7
    line = ok(OCEx.edge({0, 0, 0}, {1, 0, 0}))
    assert {:ok, %{center: nil, axis: nil}} = OCEx.edge_info(line)
  end

  test "a tightly spaced loft station yields a planar filled section" do
    body = ok(OCEx.from_brep(File.read!(Path.join(__DIR__, "fixtures/rolled-edge.brep"))))
    before = ok(OCEx.to_brep(body))

    for sign <- [1, -1] do
      section = ok(OCEx.section(body, {0, 0, 0.085}, {0, 0, sign}))
      assert_valid(section)
      # The tight smooth loft has an extra thin section strip; do not
      # incorrectly replace it with a single rectangle between stations.
      assert length(ok(OCEx.faces(section))) == 2
      assert_in_delta ok(OCEx.distance_to_point(section, {35, 5, 0.085})), 0, 1.0e-7
      assert ok(OCEx.distance_to_point(section, {35, 2, 0.085})) > 0.5

      for face <- ok(OCEx.faces(section)) do
        info = ok(OCEx.face_info(face))
        assert info.type == :plane
        assert elem(info.normal, 2) * sign > 0.99
      end

      assert_in_delta volume(ok(OCEx.extrude(section, {0, 0, 0.2}))),
                      ok(OCEx.area(section)) * 0.2,
                      ok(OCEx.area(section)) * 0.2 * 1.0e-6
    end

    assert ok(OCEx.to_brep(body)) == before
  end
end
