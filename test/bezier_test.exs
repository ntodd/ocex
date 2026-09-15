defmodule OCEx.BezierTest do
  use ExUnit.Case, async: true

  defp near({x, y, z}, {a, b, c}) do
    assert_in_delta x, a, 1.0e-8
    assert_in_delta y, b, 1.0e-8
    assert_in_delta z, c, 1.0e-8
  end

  test "cubic follows its control polygon, endpoint tangents, and Bernstein polynomial" do
    points = [{0, 0, 3}, {0, 4, 3}, {4, 4, 3}, {4, 0, 3}]
    assert {:ok, edge} = OCEx.bezier(points)
    assert {:ok, true} = OCEx.valid?(edge)

    for i <- 0..20 do
      t = i / 20
      assert {:ok, sample} = OCEx.edge_sample(edge, t)
      near(sample.point, {12 * t * t - 8 * t * t * t, 12 * t * (1 - t), 3})
    end

    assert {:ok, %{tangent: first}} = OCEx.edge_sample(edge, 0)
    assert {:ok, %{tangent: last}} = OCEx.edge_sample(edge, 1)
    near(first, {0, 1, 0})
    near(last, {0, -1, 0})
    assert {:ok, distance} = OCEx.distance_to_point(edge, {0, 4, 3})
    assert distance > 1
  end

  test "linear, quadratic, and maximum degree curves retain analytic midpoints" do
    for points <- [
          [{0, 0, 0}, {2, 0, 0}],
          [{0, 0, 0}, {1, 2, 0}, {2, 0, 0}],
          for(i <- 0..25, do: {i, 0, 0})
        ] do
      assert {:ok, edge} = OCEx.bezier(points)
      assert {:ok, %{point: point}} = OCEx.edge_sample(edge, 0.5)

      expected =
        case length(points) do
          2 -> {1, 0, 0}
          3 -> {1, 1, 0}
          26 -> {12.5, 0, 0}
        end

      near(point, expected)
    end
  end

  test "repeated control points and closed curves are permitted; collapsed curves are not" do
    assert {:ok, _} = OCEx.bezier([{0, 0, 0}, {0, 0, 0}, {2, 1, 0}])
    assert {:ok, closed} = OCEx.bezier([{0, 0, 0}, {2, 3, 0}, {-2, 3, 0}, {0, 0, 0}])
    assert {:ok, true} = OCEx.valid?(closed)

    for points <- [
          nil,
          [],
          [{0, 0, 0}],
          [{0, 0, 0}, {0, 0, 0}],
          [{0, 0, 0}, {1, 2}],
          [{0, 0, 0}, {:bad, 0, 0}],
          [{0, 0, 0} | :bad],
          for(i <- 0..26, do: {i, 0, 0})
        ] do
      assert {:error, :invalid_argument} = OCEx.bezier(points)
    end
  end
end
