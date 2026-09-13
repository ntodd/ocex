defmodule OCEx.ProjectionTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  defp circle(radius, z) do
    edge = ok(OCEx.circle(radius)) |> OCEx.translate({0, 0, z}) |> ok()
    ok(OCEx.wire([edge]))
  end

  defp target_face do
    rectangle(30, 30) |> OCEx.face() |> ok() |> OCEx.translate({-15, -15, 0}) |> ok()
  end

  test "parallel projection preserves outline dimensions and leaves both inputs unchanged" do
    source = circle(3, 8)
    target = target_face()
    before_source = ok(OCEx.to_brep(source))
    before_target = ok(OCEx.to_brep(target))

    for direction <- [{0, 0, -1}, {0, 0, 7}] do
      result = ok(OCEx.project(source, target, direction: direction))
      assert_valid(result)
      assert length(ok(OCEx.wires(result))) == 1
      assert_in_delta ok(OCEx.length(result)), 6 * :math.pi(), 1.0e-6
      assert_in_delta ok(OCEx.area(ok(OCEx.face(result)))), 9 * :math.pi(), 1.0e-6

      for vertex <- ok(OCEx.vertices(result)),
          do: assert_in_delta(elem(ok(OCEx.point(vertex)), 2), 0, 1.0e-6)
    end

    assert ok(OCEx.to_brep(source)) == before_source
    assert ok(OCEx.to_brep(target)) == before_target
  end

  test "a solid target retains projections on both front and back faces" do
    target = ok(OCEx.box(20, 20, 4)) |> OCEx.translate({-10, -10, 0}) |> ok()
    result = ok(OCEx.project(circle(3, 10), target, direction: {0, 0, -1}))
    assert length(ok(OCEx.wires(result))) == 2
    assert_in_delta ok(OCEx.length(result)), 12 * :math.pi(), 1.0e-6
    z = for edge <- ok(OCEx.edges(result)), do: elem(ok(OCEx.edge_sample(edge, 0.5)).point, 2)
    assert Enum.any?(z, &(abs(&1) < 1.0e-6))
    assert Enum.any?(z, &(abs(&1 - 4) < 1.0e-6))
  end

  test "conical projection scales an outline by the source and target plane distances" do
    result = ok(OCEx.project(circle(2, 5), target_face(), from: {0, 0, 10}))
    assert length(ok(OCEx.wires(result))) == 1
    assert_in_delta ok(OCEx.length(result)), 8 * :math.pi(), 1.0e-6
    assert_in_delta ok(OCEx.area(ok(OCEx.face(result)))), 16 * :math.pi(), 1.0e-6
  end

  test "projection onto a cylinder produces exact curves on both sides" do
    cylinder = ok(OCEx.cylinder(5, 10))

    side =
      Enum.find(ok(OCEx.faces(cylinder)), &match?({:ok, %{type: :cylinder}}, OCEx.face_info(&1)))

    edge = ok(OCEx.edge({-3, -10, 5}, {3, -10, 5}))
    result = ok(OCEx.project(edge, side, direction: {0, 1, 0}))
    assert length(ok(OCEx.wires(result))) == 2
    assert_in_delta ok(OCEx.length(result)), 20 * :math.asin(3 / 5), 1.0e-5

    for projected <- ok(OCEx.edges(result)), fraction <- [0, 0.25, 0.5, 0.75, 1] do
      {x, y, z} = ok(OCEx.edge_sample(projected, fraction)).point
      assert_in_delta x * x + y * y, 25, 1.0e-6
      assert_in_delta z, 5, 1.0e-6
    end
  end

  test "face boundaries including holes and separate source curves remain wires" do
    ring = ok(OCEx.cut(ok(OCEx.cylinder(4, 1)), ok(OCEx.cylinder(2, 1))))
    face = ok(OCEx.section(ring, {0, 0, 1}, {0, 0, 1}))
    result = ok(OCEx.project(face, target_face(), direction: {0, 0, -1}))
    assert length(ok(OCEx.wires(result))) == 2
    assert ok(OCEx.faces(result)) == []
    assert_in_delta ok(OCEx.length(result)), 12 * :math.pi(), 1.0e-6
    sources = ok(OCEx.compound([circle(1, 3), circle(2, 3)]))

    assert length(ok(OCEx.wires(ok(OCEx.project(sources, target_face(), direction: {0, 0, 1}))))) ==
             2
  end

  test "a partial hit clips curves to the target face and a complete miss fails" do
    target = rectangle(4, 6) |> OCEx.face() |> ok()
    source = ok(OCEx.edge({-2, 3, 5}, {8, 3, 5}))
    result = ok(OCEx.project(source, target, direction: {0, 0, -1}))
    assert_in_delta ok(OCEx.length(result)), 4, 1.0e-6
    missed = ok(OCEx.translate(source, {0, 20, 0}))
    assert {:error, :projection_failed} = OCEx.project(missed, target, direction: {0, 0, -1})
  end

  test "projection options and topology failures are tagged" do
    source = circle(2, 5)
    target = target_face()

    for opts <- [
          [],
          [direction: {0, 0, 1}, from: {0, 0, 10}],
          [direction: {0, 0, 1}, direction: {0, 0, -1}],
          [unknown: 1],
          nil
        ] do
      assert {:error, :invalid_options} = OCEx.project(source, target, opts)
    end

    assert {:error, :invalid_argument} = OCEx.project(source, target, direction: {0, 0, 0})
    assert {:error, :invalid_argument} = OCEx.project(source, target, from: :bad)

    assert {:error, :wrong_shape_type} =
             OCEx.project(ok(OCEx.box(1, 1, 1)), target, direction: {0, 0, 1})

    assert {:error, :wrong_shape_type} = OCEx.project(source, source, direction: {0, 0, 1})
  end

  test "conical projection follows the source half-rays and rejects targets behind the apex" do
    source = circle(2, 5)
    target = target_face()

    for {z, radius} <- [{-5, 6}, {2, 3.2}, {8, 0.8}] do
      projected =
        ok(OCEx.project(source, ok(OCEx.translate(target, {0, 0, z})), from: {0, 0, 10}))

      assert_in_delta ok(OCEx.length(projected)), 2 * :math.pi() * radius, 1.0e-6
    end

    assert {:error, :projection_failed} =
             OCEx.project(source, ok(OCEx.translate(target, {0, 0, 15})), from: {0, 0, 10})
  end

  test "target holes split projected paths and failed source collections return an error" do
    outer = rectangle(10, 10) |> OCEx.face() |> ok()
    hole = rectangle(2, 2) |> OCEx.face() |> ok() |> OCEx.translate({4, 4, 0}) |> ok()
    target = ok(OCEx.cut(outer, hole))
    source = ok(OCEx.edge({-2, 5, 5}, {12, 5, 5}))
    projected = ok(OCEx.project(source, target, direction: {0, 0, -1}))
    assert length(ok(OCEx.wires(projected))) == 2
    assert_in_delta ok(OCEx.length(projected)), 8, 1.0e-6
    missed = ok(OCEx.translate(source, {0, 20, 0}))

    assert {:error, :projection_failed} =
             OCEx.project(ok(OCEx.compound([source, missed])), target, direction: {0, 0, -1})

    assert {:error, :wrong_shape_type} =
             OCEx.project(source, ok(OCEx.compound([target, source])), direction: {0, 0, -1})
  end
end
