defmodule OCEx.OffsetTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  defp cylinder_wall(radius, height) do
    OCEx.cylinder(radius, height)
    |> ok()
    |> OCEx.faces()
    |> ok()
    |> Enum.find(&match?({:ok, %{type: :cylinder}}, OCEx.face_info(&1)))
  end

  test "solid offsets distinguish sharp intersection joins from rounded joins" do
    box = ok(OCEx.box(20, 16, 10))
    before = ok(OCEx.to_brep(box))
    outward = ok(OCEx.offset(box, 2, join: :intersection))
    inward = ok(OCEx.offset(box, -2))
    assert_in_delta volume(outward), 24 * 20 * 14, 1.0e-5
    assert_in_delta volume(inward), 16 * 12 * 6, 1.0e-5
    rounded = ok(OCEx.offset(box, 2))
    # Parallel body: original + face slabs + quarter cylinders + sphere octants.
    expected =
      3200 + 2 * (320 + 200 + 160) * 2 + :math.pi() * (20 + 16 + 10) * 4 + 4 / 3 * :math.pi() * 8

    assert_in_delta volume(rounded), expected, 1.0e-5
    assert ok(OCEx.to_brep(box)) == before
    assert {:error, _} = OCEx.offset(box, -20)
  end

  test "sphere offsets change radius without replacing the source" do
    sphere = ok(OCEx.sphere(5))

    for distance <- [-1, 1] do
      shape = ok(OCEx.offset(sphere, distance))
      assert_valid(shape)
      assert_in_delta volume(shape), 4 / 3 * :math.pi() * :math.pow(5 + distance, 3), 1.0e-5
    end

    assert {:error, _} = OCEx.offset(sphere, -6)
  end

  test "surface offset moves a cylinder wall along its normals without filling it" do
    wall = cylinder_wall(10, 12)
    offset = ok(OCEx.offset(wall, 2))
    assert ok(OCEx.solids(offset)) == []
    assert_in_delta ok(OCEx.area(offset)), 2 * :math.pi() * 12 * 12, 1.0e-5
    assert_in_delta ok(OCEx.area(wall)), 2 * :math.pi() * 10 * 12, 1.0e-5
  end

  test "thickening curved surfaces builds a tube on the chosen side" do
    wall = cylinder_wall(10, 12)
    before = ok(OCEx.to_brep(wall))

    for {thickness, expected} <- [
          {2, (144 - 100) * 12 * :math.pi()},
          {-2, (100 - 64) * 12 * :math.pi()}
        ] do
      thick = ok(OCEx.thicken(wall, thickness))
      assert_valid(thick)
      assert length(ok(OCEx.solids(thick))) == 1
      assert_in_delta volume(thick), expected, 1.0e-5
    end

    assert ok(OCEx.to_brep(wall)) == before
    assert {:error, _} = OCEx.thicken(wall, -20)
  end

  test "thickening an annular planar face preserves its hole" do
    ring = ok(OCEx.cut(ok(OCEx.cylinder(5, 10)), ok(OCEx.cylinder(2, 10))))
    section = ok(OCEx.section(ring, {0, 0, 3}, {0, 0, 1}))

    for thickness <- [-2, 2] do
      thick = ok(OCEx.thicken(section, thickness))
      assert_in_delta volume(thick), 42 * :math.pi(), 1.0e-5
    end
  end

  test "sewn connected faces thicken with an intersection join at their corner" do
    body = ok(OCEx.box(10, 10, 10))

    faces =
      Enum.filter(ok(OCEx.faces(body)), fn face ->
        {:ok, info} = OCEx.face_info(face)
        elem(info.normal, 0) < -0.99 or elem(info.normal, 1) < -0.99
      end)

    assert length(faces) == 2
    surface = ok(OCEx.sew(faces))
    assert {:ok, :shell} = OCEx.shape_type(surface)
    thick = ok(OCEx.thicken(surface, 1))
    assert_valid(thick)
    assert_in_delta volume(thick), (11 * 11 - 10 * 10) * 10, 1.0e-5
  end

  test "disconnected surface collections remain independently thickened regions" do
    face = ok(OCEx.section(ok(OCEx.box(4, 5, 6)), {0, 0, 3}, {0, 0, 1}))
    other = ok(OCEx.translate(face, {10, 0, 0}))
    surface = ok(OCEx.sew([face, other]))
    thick = ok(OCEx.thicken(surface, 2))
    assert length(ok(OCEx.solids(thick))) == 2
    assert_in_delta volume(thick), 80, 1.0e-5
  end

  test "offset and thickening reject invalid amounts, options and topology" do
    body = ok(OCEx.box(10, 10, 10))
    face = hd(ok(OCEx.faces(body)))
    edge = hd(ok(OCEx.edges(body)))

    for op <- [:offset, :thicken], amount <- [0, 1.0e-8, nil] do
      assert {:error, :invalid_argument} = apply(OCEx, op, [face, amount])
    end

    for op <- [:offset, :thicken],
        opts <- [[join: :bad], [join: :arc, join: :intersection], nil] do
      assert {:error, :invalid_options} = apply(OCEx, op, [face, 1, opts])
    end

    assert {:error, :wrong_shape_type} = OCEx.offset(edge, 1)
    assert {:error, :wrong_shape_type} = OCEx.thicken(body, 1)
    assert {:error, :closed_shell} = OCEx.thicken(ok(OCEx.sew(ok(OCEx.faces(body)))), 1)
    assert {:error, :empty_selection} = OCEx.sew([])
    assert {:error, :duplicate_subshape} = OCEx.sew([face, face])
    assert {:error, :wrong_shape_type} = OCEx.sew([edge])
  end

  test "rounded thickening joins and independent solid offsets preserve analytic measures" do
    body = ok(OCEx.box(10, 10, 10))

    faces =
      Enum.filter(ok(OCEx.faces(body)), fn face ->
        {:ok, info} = OCEx.face_info(face)
        elem(info.normal, 0) < -0.99 or elem(info.normal, 1) < -0.99
      end)

    surface = ok(OCEx.sew(faces))
    rounded = ok(OCEx.thicken(surface, 1, join: :arc))
    assert_in_delta volume(rounded), 200 + :math.pi() / 4 * 10, 1.0e-5
    other = ok(OCEx.translate(body, {30, 0, 0}))
    expanded = ok(OCEx.offset(ok(OCEx.compound([body, other])), 1, join: :intersection))
    assert length(ok(OCEx.solids(expanded))) == 2
    assert_in_delta volume(expanded), 2 * 12 * 12 * 12, 1.0e-5
  end

  test "offset and thickened resources survive their producing process" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        wall = cylinder_wall(10, 12)
        thick = ok(OCEx.thicken(wall, -2))
        offset = ok(OCEx.offset(ok(OCEx.sphere(5)), 1))
        send(parent, {:shapes, thick, offset, ok(OCEx.faces(thick))})
      end)

    assert_receive {:shapes, thick, offset, faces}, 5000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    :erlang.garbage_collect()
    assert_valid(thick)
    assert_valid(offset)
    for face <- faces, do: assert(match?({:ok, _}, OCEx.face_info(face)))
  end
end
