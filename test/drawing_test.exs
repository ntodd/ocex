defmodule OCEx.DrawingTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  defp drawing(shape, normal \\ {0, 0, 1}, origin \\ {0, 0, 0}, x \\ {1, 0, 0}, opts \\ []),
    do: ok(OCEx.drawing(shape, origin, normal, x, opts))

  defp assert_bounds(shape, expected) do
    {low, high} = ok(OCEx.bounds(shape))

    for {actual, wanted} <- Enum.zip(Tuple.to_list(low) ++ Tuple.to_list(high), expected),
        do: assert_in_delta(actual, wanted, 1.0e-6)
  end

  test "orthographic coordinates follow the view frame and ignore depth" do
    body = ok(OCEx.box(10, 6, 4))
    before = ok(OCEx.to_brep(body))

    for z <- [0, 30] do
      result = drawing(body, {0, 0, 1}, {2, 3, z})
      assert_valid(result.visible)
      assert_valid(result.hidden)
      assert_bounds(result.visible, [-2, -3, 0, 8, 3, 0])
    end

    rotated = drawing(body, {0, 0, 5}, {0, 0, 0}, {0, 2, 3})
    assert_bounds(rotated.visible, [0, -10, 0, 6, 0, 0])
    side = drawing(body, {1, 0, 0}, {0, 0, 0}, {0, 1, 0})
    assert_bounds(side.visible, [0, 0, 0, 6, 4, 0])
    assert ok(OCEx.to_brep(body)) == before
  end

  test "sphere and cylinder silhouettes retain analytic curves without seams" do
    sphere = ok(OCEx.sphere(3))
    result = drawing(sphere)
    assert_bounds(result.visible, [-3, -3, 0, 3, 3, 0])
    assert_in_delta ok(OCEx.length(result.visible)), 6 * :math.pi(), 1.0e-6
    assert ok(OCEx.edges(result.hidden)) == []

    assert Enum.all?(
             ok(OCEx.edges(result.visible)),
             &match?({:ok, %{type: :circle}}, OCEx.edge_info(&1))
           )

    result = drawing(ok(OCEx.cylinder(5, 10)))
    assert_in_delta ok(OCEx.length(result.visible)), 10 * :math.pi(), 1.0e-6
  end

  test "front surfaces hide rear curves and reversing the normal reveals them" do
    cover = rectangle(10, 10) |> OCEx.face() |> ok() |> OCEx.translate({-5, -5, 5}) |> ok()
    circle = ok(OCEx.circle(2))
    source = ok(OCEx.compound([cover, circle]))
    before = ok(OCEx.to_brep(source))
    front = drawing(source)
    assert_in_delta ok(OCEx.length(front.visible)), 40, 1.0e-6
    assert_in_delta ok(OCEx.length(front.hidden)), 4 * :math.pi(), 1.0e-6
    back = drawing(source, {0, 0, -1})
    assert_in_delta ok(OCEx.length(back.visible)), 40 + 4 * :math.pi(), 1.0e-6
    assert ok(OCEx.edges(back.hidden)) == []
    assert ok(OCEx.to_brep(source)) == before
  end

  test "occlusion splits an edge into visible and hidden intervals" do
    cover = rectangle(4, 4) |> OCEx.face() |> ok() |> OCEx.translate({-2, -2, 5}) |> ok()
    edge = ok(OCEx.edge({-5, 0, 0}, {5, 0, 0}))
    result = drawing(ok(OCEx.compound([cover, edge])))
    assert_in_delta ok(OCEx.length(result.hidden)), 4, 1.0e-6
    assert_in_delta ok(OCEx.length(result.visible)), 22, 1.0e-6
    assert_bounds(result.hidden, [-2, 0, 0, 2, 0, 0])
  end

  test "smooth face boundaries are opt-in and do not alter the input" do
    box = ok(OCEx.box(10, 8, 6))
    body = ok(OCEx.fillet(box, ok(OCEx.edges(box)), 1))
    before = ok(OCEx.to_brep(body))
    plain = drawing(body, {1, 1, 1})
    smooth = drawing(body, {1, 1, 1}, {0, 0, 0}, {1, 0, 0}, tangents: true)
    assert ok(OCEx.length(smooth.visible)) > ok(OCEx.length(plain.visible))
    assert ok(OCEx.to_brep(body)) == before
  end

  test "empty and end-on edge views have empty edge collections" do
    for source <- [ok(OCEx.compound([])), ok(OCEx.edge({0, 0, 0}, {0, 0, 5}))] do
      result = drawing(source)
      assert ok(OCEx.edges(result.visible)) == []
      assert ok(OCEx.edges(result.hidden)) == []
    end
  end

  test "malformed frames, options and unsupported topology return tagged errors" do
    body = ok(OCEx.box(1, 2, 3))

    for {normal, x} <- [{{0, 0, 0}, {1, 0, 0}}, {{0, 0, 1}, {0, 0, 1}}, {{0, 0, 1}, :bad}] do
      assert {:error, :invalid_argument} = OCEx.drawing(body, {0, 0, 0}, normal, x)
    end

    for opts <- [[tangents: :yes], [tangents: true, tangents: false], [unknown: 1], nil] do
      assert {:error, :invalid_options} =
               OCEx.drawing(body, {0, 0, 0}, {0, 0, 1}, {1, 0, 0}, opts)
    end

    vertex = hd(ok(OCEx.vertices(body)))
    assert {:error, :wrong_shape_type} = OCEx.drawing(vertex, {0, 0, 0}, {0, 0, 1}, {1, 0, 0})

    assert {:error, :wrong_shape_type} =
             OCEx.drawing(ok(OCEx.compound([body, vertex])), {0, 0, 0}, {0, 0, 1}, {1, 0, 0})
  end

  test "polyline sampling preserves line endpoints and the direction of arcs" do
    line = ok(OCEx.edge({2, 3, 4}, {7, 8, 9}))
    assert [[{2.0, 3.0, 4.0}, {7.0, 8.0, 9.0}]] = ok(OCEx.polylines(line))
    arc = ok(OCEx.arc({0, 0, 0}, {0, 0, 1}, {1, 0, 0}, 5, 90, -90))
    [points] = ok(OCEx.polylines(arc))
    {x, y, _} = hd(points)
    assert_in_delta x, 0, 1.0e-6
    assert_in_delta y, 5, 1.0e-6
    {x, y, _} = List.last(points)
    assert_in_delta x, 5, 1.0e-6
    assert_in_delta y, 0, 1.0e-6
  end

  test "circle sampling obeys the requested chord deflection and retains closure" do
    source = ok(OCEx.circle(10))
    before = ok(OCEx.to_brep(source))
    [coarse] = ok(OCEx.polylines(source, 0.1, 1))
    [fine] = ok(OCEx.polylines(source, 0.001, 1))
    assert length(fine) > length(coarse)

    for {points, tolerance} <- [{coarse, 0.1}, {fine, 0.001}] do
      for [a, b] <- Enum.chunk_every(points, 2, 1, :discard) do
        {x, y, _} = a
        {u, v, _} = b
        radius = :math.sqrt(:math.pow((x + u) / 2, 2) + :math.pow((y + v) / 2, 2))
        assert 10 - radius <= tolerance + 1.0e-7
      end

      assert_in_delta elem(hd(points), 0), elem(List.last(points), 0), 1.0e-6
      assert_in_delta elem(hd(points), 1), elem(List.last(points), 1), 1.0e-6
    end

    assert ok(OCEx.to_brep(source)) == before
    assert {:ok, []} = OCEx.polylines(ok(OCEx.compound([])))

    for bad <- [0, -1, :bad],
        do: assert({:error, :invalid_argument} = OCEx.polylines(source, bad))

    assert {:error, :invalid_argument} = OCEx.polylines(source, 0.01, 0)
  end

  test "coarse sampling retains three distinct points and closure on a circle" do
    circle = ok(OCEx.circle(1))
    [points] = ok(OCEx.polylines(circle, 100, 100))
    assert length(points) >= 4
    assert Enum.any?(points, fn {_, y, _} -> abs(y) > 0.1 end)
  end
end
