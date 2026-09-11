defmodule OCEx.ErrorsTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  for {op, args} <- [
        {:box, [0, 1, 1]},
        {:box, [-1, 1, 1]},
        {:box, ["1", 1, 1]},
        {:box, [nil, 1, 1]},
        {:box, [1.0e-12, 1, 1]},
        {:box, [Integer.pow(10, 400), 1, 1]},
        {:cylinder, [0, 1]},
        {:cylinder, [1, -1]},
        {:sphere, [0]},
        {:circle, [-1]},
        {:cone, [0, 0, 1]},
        {:cone, [1, 1, 1]},
        {:cone, [-1, 2, 1]},
        {:edge, [{0, 0, 0}, {0, 0, 0}]},
        {:edge, [{0, 0}, {1, 1, 1}]},
        {:wire, [[]]},
        {:wire, [:invalid]},
        {:from_brep, ["garbage"]},
        {:from_brep, [<<>>]},
        {:read_step, ["/definitely/not/a/file.step"]}
      ] do
    test "rejects #{op} #{String.slice(inspect(args, limit: 5), 0, 120)}" do
      assert {:error, _} = apply(OCEx, unquote(op), unquote(Macro.escape(args)))
    end
  end

  test "improper public shape lists return errors instead of raising" do
    body = ok(OCEx.box(10, 10, 10))
    [edge | _] = ok(OCEx.edges(body))
    improper = [edge | :not_a_list]
    assert {:error, :invalid_argument} = OCEx.wire(improper)
    assert {:error, :invalid_argument} = OCEx.compound(improper)
    assert {:error, :invalid_argument} = OCEx.loft(improper)
    assert {:error, :invalid_argument} = OCEx.fillet(body, improper, 1)
  end

  test "invalid shape inputs never enter unchecked native code" do
    for bad <- [nil, 1, %{}, %OCEx.Shape{ref: make_ref()}] do
      assert {:error, :invalid_argument} = OCEx.volume(bad)
      assert {:error, :invalid_argument} = OCEx.edges(bad)
    end

    assert {:error, :invalid_argument} = OCEx.Native.call(:not_an_operation, [])
    assert {:error, :invalid_argument} = OCEx.Native.call(:box, [1])
    assert {:error, :invalid_argument} = OCEx.Native.call(:box, :bad)
  end

  test "wrong topology and invalid transforms are rejected" do
    box = ok(OCEx.box(10, 10, 10))
    face = ok(OCEx.face(rectangle()))

    for result <- [
          OCEx.face(box),
          OCEx.edge_info(box),
          OCEx.face_info(box),
          OCEx.point(box),
          OCEx.extrude(box, {0, 0, 1}),
          OCEx.extrude(face, {0, 0, 0}),
          OCEx.translate(box, {1, 2}),
          OCEx.rotate(box, {0, 0, 0}, {0, 0, 0}, 90),
          OCEx.scale(box, 0),
          OCEx.mesh(box, 0),
          OCEx.mesh(box, -1),
          OCEx.loft([]),
          OCEx.loft([box, box])
        ] do
      assert {:error, _} = result
    end
  end

  test "disconnected wires and open face boundaries fail" do
    a = ok(OCEx.edge({0, 0, 0}, {1, 0, 0}))
    b = ok(OCEx.edge({10, 0, 0}, {11, 0, 0}))
    assert {:error, _} = OCEx.wire([a, b])
    assert {:error, _} = OCEx.face(ok(OCEx.wire([a])))
  end

  test "fillets reject empty, foreign, stale, duplicate and oversized selections" do
    a = ok(OCEx.box(10, 10, 10))
    b = ok(OCEx.box(10, 10, 10))
    edges = vertical_edges(a)
    assert {:error, _} = OCEx.fillet(a, [], 1)
    assert {:error, _} = OCEx.fillet(a, edges, -1)
    assert {:error, _} = OCEx.fillet(a, edges, 1000)
    assert {:error, _} = OCEx.fillet(a, [hd(edges), hd(edges)], 1)
    assert {:error, :foreign_subshape} = OCEx.fillet(b, edges, 1)
    newer = ok(OCEx.translate(a, {1, 0, 0}))
    assert {:error, :foreign_subshape} = OCEx.fillet(newer, edges, 1)
    assert_valid(a)
    assert_in_delta volume(a), 1000, 1.0e-7
  end

  test "file errors and embedded NUL paths are reported" do
    body = ok(OCEx.box(1, 2, 3))
    assert {:error, _} = OCEx.write_step(body, "/definitely/not/a/directory/a.step")
    assert {:error, _} = OCEx.write_stl(body, "/definitely/not/a/directory/a.stl")
    assert {:error, :invalid_argument} = OCEx.write_step(body, "bad\0path")
  end
end
