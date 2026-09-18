defmodule OCEx.PlanarArtworkTest do
  use ExUnit.Case, async: true

  defp wire(points) do
    points = points ++ [hd(points)]

    edges =
      Enum.chunk_every(points, 2, 1, :discard)
      |> Enum.map(fn [a, b] ->
        {:ok, e} = OCEx.edge(a, b)
        e
      end)

    {:ok, w} = OCEx.wire(edges)
    w
  end

  defp square(x, y, size),
    do: wire([{x, y, 0}, {x + size, y, 0}, {x + size, y + size, 0}, {x, y + size, 0}])

  defp area(shape, expected) do
    assert {:ok, true} = OCEx.valid?(shape)
    assert {:ok, a} = OCEx.area(shape)
    assert_in_delta a, expected, 1.0e-5
  end

  test "fill rules distinguish nested and overlapping contours" do
    outer = square(0, 0, 10)
    inner = square(2, 2, 6)
    assert {:ok, solid} = OCEx.planar_fill([outer, inner], :nonzero)
    area(solid, 100)
    assert {:ok, ring} = OCEx.planar_fill([outer, inner], :evenodd)
    area(ring, 64)
    assert {:ok, overlap} = OCEx.planar_fill([outer, square(5, 0, 10)], :evenodd)
    area(overlap, 100)
    assert {:ok, union} = OCEx.planar_fill([outer, square(5, 0, 10)], :nonzero)
    area(union, 150)
    assert {:ok, raised} = OCEx.extrude(ring, {0, 0, 2})
    assert {:ok, volume} = OCEx.volume(raised)
    assert_in_delta volume, 128, 1.0e-5
  end

  test "self intersections and disconnected islands retain their filled areas" do
    bow = wire([{0, 0, 0}, {4, 4, 0}, {0, 4, 0}, {4, 0, 0}])
    assert {:ok, faces} = OCEx.planar_fill([bow, square(10, 0, 2)], :evenodd)
    area(faces, 12)
  end

  test "stroke cap and join semantics have analytic area and bounds" do
    {:ok, e} = OCEx.edge({0, 0, 0}, {10, 0, 0})
    {:ok, w} = OCEx.wire([e])
    assert {:ok, butt} = OCEx.stroke(w, 2)
    area(butt, 20)
    assert {:ok, square} = OCEx.stroke(w, 2, cap: :square)
    area(square, 24)
    assert {:ok, round} = OCEx.stroke(w, 2, cap: :round)
    area(round, 20 + :math.pi())
    assert {:ok, outline} = OCEx.stroke(square(0, 0, 10), 2, join: :miter)
    area(outline, 80)
    assert {:ok, bevel} = OCEx.stroke(square(0, 0, 10), 2, join: :bevel)
    area(bevel, 78)
  end

  test "affine placement scales area and preserves the input" do
    {:ok, face} = OCEx.planar_fill([square(0, 0, 2)], :nonzero)
    assert {:ok, placed} = OCEx.affine_transform(face, {2, 0, 0, 3, 5, 7})
    area(placed, 24)
    area(face, 4)
    assert {:ok, {{x, y, _}, {xx, yy, _}}} = OCEx.bounds(placed)
    assert_in_delta x, 5, 1.0e-6
    assert_in_delta y, 7, 1.0e-6
    assert_in_delta xx, 9, 1.0e-6
    assert_in_delta yy, 13, 1.0e-6
    assert {:error, _} = OCEx.affine_transform(face, {0, 0, 0, 0, 0, 0})
  end

  @tag timeout: 60_000
  test "round curved strokes keep annulus area and valid extrusion" do
    {:ok, circle} = OCEx.circle(10)
    {:ok, wire} = OCEx.wire([circle])
    {:ok, face} = OCEx.stroke(wire, 2, join: :round, tolerance: 0.005)
    assert {:ok, true} = OCEx.valid?(face)
    assert {:ok, measured} = OCEx.area(face)
    assert_in_delta measured, 40 * :math.pi(), 0.1
    assert {:ok, solid} = OCEx.extrude(face, {0, 0, 1.2})
    assert {:ok, volume} = OCEx.volume(solid)
    assert_in_delta volume, measured * 1.2, 0.001
  end

  test "a circle stroke as wide as its diameter becomes a valid disk" do
    {:ok, circle} = OCEx.circle(1)
    {:ok, wire} = OCEx.wire([circle])

    for width <- [2, 3] do
      assert {:ok, face} = OCEx.stroke(wire, width, join: :round)
      assert {:ok, true} = OCEx.valid?(face)
      area(face, :math.pi() * :math.pow(1 + width / 2, 2))
    end
  end

  test "bad inputs return tagged errors" do
    assert {:error, _} = OCEx.planar_fill([], :invalid)
    {:ok, e} = OCEx.edge({0, 0, 1}, {10, 0, 1})
    {:ok, w} = OCEx.wire([e])
    assert {:error, :nonplanar_profile} = OCEx.stroke(w, 2)
    assert {:error, _} = OCEx.stroke(w, 0)
    assert {:error, :invalid_options} = OCEx.stroke(w, 2, cap: :triangle)
  end

  test "ordered wire sampling handles curves, arbitrary planes and closed boundaries" do
    w = square(1, 2, 4)
    {:ok, points} = OCEx.wire_points(w)
    assert hd(points) == List.last(points)
    assert length(points) == 5
    {:ok, raised} = OCEx.translate(w, {0, 0, 7})
    {:ok, points} = OCEx.wire_points(raised)
    assert Enum.all?(points, fn {_, _, z} -> abs(z - 7) < 1.0e-8 end)
    assert {:error, :nonplanar_profile} = OCEx.planar_fill([raised])
    assert {:error, _} = OCEx.wire_points(w, 0)
  end

  test "native artwork operations do not mutate input BREP or selection identity" do
    w = square(0, 0, 10)
    {:ok, before} = OCEx.to_brep(w)
    {:ok, _} = OCEx.planar_fill([w])
    {:ok, _} = OCEx.stroke(w, 1, join: :round)
    {:ok, _} = OCEx.affine_transform(w, {1, 0, 0.3, 2, 0, 0})
    {:ok, _} = OCEx.wire_points(w)
    assert {:ok, ^before} = OCEx.to_brep(w)
  end

  test "XY affine similarities leave small nonzero Z coordinates unchanged" do
    {:ok, edge} = OCEx.edge({0, 0, 1.0e-8}, {1, 0, 1.0e-8})
    {:ok, placed} = OCEx.affine_transform(edge, {1.0e6, 0, 0, 1.0e6, 0, 0})
    {:ok, %{point: {_, _, z}}} = OCEx.edge_sample(placed, 0.5)
    assert_in_delta z, 1.0e-8, 1.0e-12
  end
end
