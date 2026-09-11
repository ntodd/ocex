defmodule OCEx.CurvesCleanupTest do
  use ExUnit.Case, async: true
  defp ok({:ok, value}), do: value

  defp near({x, y, z}, {a, b, c}) do
    assert_in_delta x, a, 1.0e-7
    assert_in_delta y, b, 1.0e-7
    assert_in_delta z, c, 1.0e-7
  end

  test "signed arcs in an arbitrary plane preserve endpoints and length" do
    arc = ok(OCEx.arc({2, 3, 4}, {1, 0, 0}, {0, 1, 0}, 5, 90, -180))
    info = ok(OCEx.edge_info(arc))
    near(info.start, {2, 3, 9})
    near(info.end, {2, 3, -1})
    assert_in_delta info.length, 5 * :math.pi(), 1.0e-8
    near(ok(OCEx.edge_sample(arc, 0.5)).point, {2, 8, 4})
  end

  test "spline interpolates every point and obeys endpoint tangents" do
    points = [{0, 0, 0}, {1, 2, 0}, {3, 1, 0}, {5, 0, 0}]
    edge = ok(OCEx.spline(points, {{0, 1, 0}, {1, 0, 0}}))
    for point <- points, do: assert_in_delta(ok(OCEx.distance_to_point(edge, point)), 0, 1.0e-7)
    near(ok(OCEx.edge_sample(edge, 0)).tangent, {0, 1, 0})
    near(ok(OCEx.edge_sample(edge, 1)).tangent, {1, 0, 0})
    assert {:ok, _} = OCEx.spline(points)
  end

  test "cleanup removes seams immutably and invalidates old selections" do
    a = ok(OCEx.box(10, 10, 10))
    b = OCEx.box(10, 10, 10) |> ok() |> OCEx.translate({10, 0, 0}) |> ok()
    joined = ok(OCEx.fuse(a, b))
    before = ok(OCEx.to_brep(joined))
    clean = ok(OCEx.clean(joined))
    assert length(ok(OCEx.faces(clean))) == 6
    assert length(ok(OCEx.edges(clean))) == 12
    assert_in_delta ok(OCEx.volume(clean)), 2000, 1.0e-8
    assert ok(OCEx.to_brep(joined)) == before
    assert {:error, :foreign_subshape} = OCEx.fillet(clean, [hd(ok(OCEx.edges(joined)))], 1)
  end

  test "cylinder axes follow placement and line intersections measure thickness" do
    body =
      OCEx.cylinder(2, 10)
      |> ok()
      |> OCEx.rotate({0, 0, 0}, {1, 0, 0}, 90)
      |> ok()
      |> OCEx.translate({3, 4, 5})
      |> ok()

    info =
      body
      |> OCEx.faces()
      |> ok()
      |> Enum.map(&ok(OCEx.face_info(&1)))
      |> Enum.find(&(&1.type == :cylinder))

    near(info.axis_origin, {3, 4, 5})
    near(info.axis_direction, {0, -1, 0})
    ray = ok(OCEx.edge({0, 0, 5}, {6, 0, 5}))
    assert_in_delta ok(OCEx.common(body, ray)) |> OCEx.length() |> ok(), 4, 1.0e-7
  end

  test "reject malformed and degenerate inputs" do
    for sweep <- [0, 361, -361, :bad],
        do:
          assert(
            {:error, :invalid_argument} = OCEx.arc({0, 0, 0}, {0, 0, 1}, {1, 0, 0}, 2, 0, sweep)
          )

    assert {:error, :invalid_argument} = OCEx.arc({0, 0, 0}, {0, 0, 0}, {1, 0, 0}, 2, 0, 90)
    assert {:error, :invalid_argument} = OCEx.arc({0, 0, 0}, {0, 0, 1}, {0, 0, 1}, 2, 0, 90)

    for points <- [[], [{0, 0, 0}], [{0, 0, 0}, {0, 0, 0}], [:bad, {1, 0, 0}], [{0, 0, 0} | :bad]],
        do: assert({:error, :invalid_argument} = OCEx.spline(points))

    assert {:error, :invalid_argument} =
             OCEx.spline([{0, 0, 0}, {1, 0, 0}], {{0, 0, 0}, {1, 0, 0}})

    edge = ok(OCEx.edge({0, 0, 0}, {1, 0, 0}))

    for u <- [-0.1, 1.1, :bad],
        do: assert({:error, :invalid_argument} = OCEx.edge_sample(edge, u))

    assert {:error, :invalid_argument} = OCEx.clean(nil)
    assert {:error, :invalid_argument} = OCEx.distance_to_point(edge, {1, 2})
  end
end
