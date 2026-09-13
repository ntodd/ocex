defmodule OCEx.MechanicalTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  test "torus has analytic volume, area and bounds" do
    body = ok(OCEx.torus(10, 2))
    assert_valid(body)
    assert_in_delta volume(body), 80 * :math.pi() * :math.pi(), 1.0e-6
    assert_in_delta ok(OCEx.area(body)), 80 * :math.pi() * :math.pi(), 1.0e-6
    assert {:ok, {low, high}} = OCEx.bounds(body)

    for {actual, expected} <-
          Enum.zip(Tuple.to_list(low) ++ Tuple.to_list(high), [-12, -12, -2, 12, 12, 2]),
        do: assert_in_delta(actual, expected, 1.0e-6)

    assert {:ok, [_]} = OCEx.solids(body)

    for {major, minor} <- [{2, 2}, {1, 2}, {0, 1}, {2, 0}, {nil, 1}] do
      assert {:error, :invalid_argument} = OCEx.torus(major, minor)
    end
  end

  test "planar mirror preserves material, outward normals and the original revision" do
    source = ok(OCEx.box(2, 3, 4))
    snapshot = ok(OCEx.to_brep(source))
    mirrored = ok(OCEx.mirror(source, {5, 0, 0}, {2, 0, 0}))
    assert_valid(mirrored)
    assert_in_delta volume(mirrored), 24, 1.0e-7
    assert {:ok, bounds} = OCEx.bounds(mirrored)
    assert bounds == {{8.0, 0.0, 0.0}, {10.0, 3.0, 4.0}}
    assert ok(OCEx.to_brep(source)) == snapshot
    twice = ok(OCEx.mirror(mirrored, {5, 0, 0}, {1, 0, 0}))
    assert_in_delta volume(ok(OCEx.cut(source, twice))), 0, 1.0e-7
    assert_in_delta volume(ok(OCEx.cut(twice, source))), 0, 1.0e-7

    for face <- ok(OCEx.faces(mirrored)) do
      info = ok(OCEx.face_info(face))
      displacement = Enum.zip_with(Tuple.to_list(info.center), [9, 1.5, 2], &(&1 - &2))
      assert Enum.zip_with(displacement, Tuple.to_list(info.normal), &*/2) |> Enum.sum() > 0
    end

    assert {:error, :invalid_argument} = OCEx.mirror(source, {0, 0, 0}, {0, 0, 0})
  end

  test "oblique mirror operates on edges, faces and compounds" do
    edge = ok(OCEx.edge({2, 0, 0}, {2, 0, 3}))
    mirrored = ok(OCEx.mirror(edge, {0, 0, 0}, {1, -1, 0}))
    info = ok(OCEx.edge_info(mirrored))

    for {actual, expected} <- Enum.zip(Tuple.to_list(info.start), [0, 2, 0]),
        do: assert_in_delta(actual, expected, 1.0e-7)

    assert_in_delta ok(OCEx.length(mirrored)), 3, 1.0e-7
    face = hd(ok(OCEx.faces(ok(OCEx.box(2, 3, 4)))))
    reflected_face = ok(OCEx.mirror(face, {0, 0, 0}, {0, 0, 1}))
    assert {:ok, :face} = OCEx.shape_type(reflected_face)
    assert_in_delta ok(OCEx.area(face)), ok(OCEx.area(reflected_face)), 1.0e-7
    compound = ok(OCEx.compound([edge, face]))
    assert {:ok, :compound} = OCEx.shape_type(ok(OCEx.mirror(compound, {0, 0, 0}, {1, 0, 0})))
  end
end
