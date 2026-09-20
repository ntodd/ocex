defmodule OCEx.TransformCopyTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  test "transformed geometry remains independent after meshing and modifying descendants" do
    source = ok(OCEx.box(4, 3, 2))
    before = ok(OCEx.to_brep(source))

    variants = [
      {ok(OCEx.translate(source, {20, 5, -2})), 24},
      {ok(OCEx.rotate(source, {1, 2, 3}, {0, 0, 1}, 37)), 24},
      {ok(OCEx.scale(source, 2)), 192}
    ]

    for {shape, expected} <- variants do
      snapshot = ok(OCEx.to_brep(shape))
      edges = ok(OCEx.edges(shape))
      rounded = ok(OCEx.fillet(shape, edges, 0.1))
      ok(OCEx.mesh(rounded))
      ok(OCEx.mesh(shape))
      assert_in_delta volume(shape), expected, 1.0e-7
      assert ok(OCEx.to_brep(shape)) == snapshot
      assert ok(OCEx.to_brep(source)) == before
    end
  end
end
