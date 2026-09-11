defmodule OCEx.ModelingTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  for {op, expected} <- [{:cut, 500}, {:fuse, 1500}, {:common, 500}] do
    test "#{op} has analytic overlap volume and preserves both inputs" do
      a = ok(OCEx.box(10, 10, 10))
      b = ok(OCEx.translate(a, {5, 0, 0}))
      result = ok(apply(OCEx, unquote(op), [a, b]))
      assert_valid(result)
      assert_in_delta volume(result), unquote(expected), 1.0e-6
      assert_in_delta volume(a), 1000, 1.0e-6
      assert_in_delta volume(b), 1000, 1.0e-6
    end
  end

  test "disjoint intersection and complete subtraction are valid empty results" do
    a = ok(OCEx.box(10, 10, 10))
    b = ok(OCEx.translate(a, {20, 0, 0}))

    for empty <- [ok(OCEx.common(a, b)), ok(OCEx.cut(a, a))] do
      assert OCEx.solids(empty) == {:ok, []}
      assert_in_delta volume(empty), 0, 1.0e-8
      assert OCEx.bounds(empty) == {:error, :empty_shape}
    end
  end

  test "touching union and Boolean identities" do
    a = ok(OCEx.box(10, 10, 10))
    b = ok(OCEx.translate(a, {10, 0, 0}))
    assert_in_delta volume(ok(OCEx.fuse(a, b))), 2000, 1.0e-6
    assert_in_delta volume(ok(OCEx.fuse(a, a))), 1000, 1.0e-6
    assert_in_delta volume(ok(OCEx.common(a, a))), 1000, 1.0e-6
  end

  test "transform composition, inverse and uniform scaling" do
    a = ok(OCEx.box(10, 20, 30))
    translated = ok(OCEx.translate(a, {2, -3, 4}))
    close_point(ok(OCEx.center_of_mass(translated)), {7, 7, 19})
    restored = ok(OCEx.translate(translated, {-2, 3, -4}))
    close_point(ok(OCEx.center_of_mass(restored)), {5, 10, 15})
    rotated = ok(OCEx.rotate(a, {0, 0, 0}, {0, 0, 1}, 90))
    close_point(ok(OCEx.center_of_mass(rotated)), {-10, 5, 15})
    assert_in_delta volume(rotated), volume(a), 1.0e-6
    scaled = ok(OCEx.scale(a, 2))
    assert_in_delta volume(scaled), 8 * volume(a), 1.0e-5
    close_point(ok(OCEx.center_of_mass(a)), {5, 10, 15})
  end

  test "vertical-edge fillets have an independent rounded-rectangle volume" do
    body = ok(OCEx.box(60, 40, 5))
    edges = vertical_edges(body)
    assert Enum.count(edges) == 4
    rounded = ok(OCEx.fillet(body, edges, 2))
    assert_valid(rounded)
    assert_in_delta volume(rounded), (60 * 40 - (4 - :math.pi()) * 4) * 5, 1.0e-5
    assert_in_delta volume(body), 12_000, 1.0e-7
    assert Enum.count(ok(OCEx.edges(body))) == 12
  end

  test "chamfers remove the expected triangular prisms" do
    body = ok(OCEx.box(60, 40, 5))
    result = ok(OCEx.chamfer(body, vertical_edges(body), 2))
    assert_valid(result)
    assert_in_delta volume(result), 12_000 - 4 * (2 * 2 / 2) * 5, 1.0e-5
  end

  test "rounded plate with a through hole matches the Smith consumer" do
    body = ok(OCEx.box(60, 40, 5))
    rounded = ok(OCEx.fillet(body, vertical_edges(body), 2))
    drill = OCEx.cylinder(4, 7) |> ok() |> OCEx.translate({30, 20, -1}) |> ok()
    result = ok(OCEx.cut(rounded, drill))
    assert_valid(result)
    expected = (2400 - (4 - :math.pi()) * 4 - :math.pi() * 16) * 5
    assert_in_delta volume(result), expected, 1.0e-5
    assert Enum.count(ok(OCEx.solids(result))) == 1
  end

  test "deterministic dimension sweep obeys Boolean volume conservation" do
    for size <- [0.1, 1.0, 17.5, 100.0] do
      a = ok(OCEx.box(size, size * 2, size * 3))
      b = ok(OCEx.translate(a, {size / 3, 0, 0}))
      union = ok(OCEx.fuse(a, b))
      intersection = ok(OCEx.common(a, b))
      difference = ok(OCEx.cut(a, b))
      tolerance = max(1.0e-7, volume(a) * 1.0e-9)
      assert_in_delta volume(union) + volume(intersection), volume(a) + volume(b), tolerance
      assert_in_delta volume(difference) + volume(intersection), volume(a), tolerance
    end
  end
end
