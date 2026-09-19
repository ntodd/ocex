defmodule OCEx.CutRemovedTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  test "checked cuts measure removed material while preserving independent inputs" do
    body = ok(OCEx.box(10, 10, 10))
    cylinder = ok(OCEx.cylinder(2, 12))
    original = ok(OCEx.to_brep(body))

    for {x, expected} <- [{5, 40 * :math.pi()}, {0, 20 * :math.pi()}, {20, 0}] do
      tool = ok(OCEx.translate(cylinder, {x, 5, -1}))
      tool_before = ok(OCEx.to_brep(tool))
      assert {:ok, result, removed} = apply(OCEx.Internal, :cut_removed, [body, tool])
      assert_valid(result)
      assert_in_delta removed, expected, 1.0e-7
      assert_in_delta volume(result), 1000 - expected, 1.0e-7
      assert ok(OCEx.to_brep(body)) == original
      assert ok(OCEx.to_brep(tool)) == tool_before
    end

    assert {:ok, empty, removed} = apply(OCEx.Internal, :cut_removed, [body, body])
    assert_in_delta volume(empty), 0, 1.0e-7
    assert_in_delta removed, 1000, 1.0e-7
  end
end
