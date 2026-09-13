defmodule OCEx.DraftTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  defp sides(body) do
    for face <- ok(OCEx.faces(body)),
        {:ok, %{normal: {_, _, z}}} = OCEx.face_info(face),
        abs(z) < 0.1,
        do: face
  end

  test "signed draft angles preserve the neutral footprint and match integrated section area" do
    body = ok(OCEx.box(20, 16, 10))
    before = ok(OCEx.to_brep(body))

    for angle <- [-5, 0, 5] do
      shape = ok(OCEx.draft(body, sides(body), {0, 0, 1}, angle, {0, 0, 0}, {0, 0, 1}))
      t = :math.tan(angle * :math.pi() / 180)
      expected = 3200 - 36 * t * 100 + 4 / 3 * t * t * 1000
      assert_valid(shape)
      assert_in_delta volume(shape), expected, 1.0e-5
      bottom = ok(OCEx.section(shape, {0, 0, 0}, {0, 0, 1}))
      top = ok(OCEx.section(shape, {0, 0, 10}, {0, 0, 1}))
      assert_in_delta ok(OCEx.area(bottom)), 320, 1.0e-5
      assert_in_delta ok(OCEx.area(top)), (20 - 20 * t) * (16 - 20 * t), 1.0e-5
    end

    assert ok(OCEx.to_brep(body)) == before
  end

  test "reversing pull reverses material change and translated neutral planes retain their footprint" do
    body = ok(OCEx.box(20, 16, 10)) |> OCEx.translate({4, 5, 6}) |> ok()
    selected = sides(body)
    a = ok(OCEx.draft(body, selected, {0, 0, -1}, 5, {0, 0, 6}, {0, 0, 1}))
    b = ok(OCEx.draft(body, selected, {0, 0, 1}, -5, {0, 0, 6}, {0, 0, 1}))
    assert_in_delta volume(a), volume(b), 1.0e-6
    assert_in_delta volume(ok(OCEx.cut(a, b))), 0, 1.0e-6
  end

  test "cylindrical walls become conical with analytic volume" do
    body = ok(OCEx.cylinder(10, 12))

    faces =
      Enum.filter(ok(OCEx.faces(body)), &match?({:ok, %{type: :cylinder}}, OCEx.face_info(&1)))

    drafted = ok(OCEx.draft(body, faces, {0, 0, 1}, 5, {0, 0, 0}, {0, 0, 1}))
    t = :math.tan(5 * :math.pi() / 180)

    assert_in_delta volume(drafted),
                    :math.pi() * (100 * 12 - 10 * t * 144 + t * t * 1728 / 3),
                    1.0e-5

    assert_valid(drafted)
  end

  test "draft enforces revision ownership and validates angles and pull vectors" do
    body = ok(OCEx.box(20, 16, 10))
    [face | _] = sides(body)
    copy = ok(OCEx.translate(body, {0, 0, 0}))

    call = fn shape, faces, pull, angle ->
      OCEx.draft(shape, faces, pull, angle, {0, 0, 0}, {0, 0, 1})
    end

    assert {:error, :foreign_subshape} = call.(copy, [face], {0, 0, 1}, 5)
    assert {:error, :duplicate_subshape} = call.(body, [face, face], {0, 0, 1}, 5)
    assert {:error, :empty_selection} = call.(body, [], {0, 0, 1}, 5)

    for angle <- [90, -90, nil] do
      assert {:error, :invalid_argument} = call.(body, [face], {0, 0, 1}, angle)
    end

    assert {:error, :invalid_argument} = call.(body, [face], {0, 0, 0}, 5)
    assert {:error, :invalid_direction} = call.(body, [face], {1, 0, 0}, 5)
    assert {:error, _} = call.(body, sides(body), {0, 0, 1}, 60)
    sphere = ok(OCEx.sphere(5))

    assert {:error, :unsupported_draft_surface} =
             call.(sphere, ok(OCEx.faces(sphere)), {0, 0, 1}, 5)
  end
end
