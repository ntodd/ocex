defmodule OCEx.TransformChainTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  test "composition preserves noncommuting rotations, translations, mirrors and ownership" do
    source = ok(OCEx.box(4, 3, 2))
    before = ok(OCEx.to_brep(source))

    steps = [
      {:translate, [{3, -2, 5}]},
      {:rotate, [{1, 2, 3}, {1, 2, 3}, 37]},
      {:mirror, [{2, 0, 0}, {1, 0, 0}]},
      {:translate, [{-1, 2, -3}]}
    ]

    expected = Enum.reduce(steps, source, fn {op, args}, s -> ok(apply(OCEx, op, [s | args])) end)
    actual = ok(OCEx.Internal.transform_chain(source, steps))
    assert_in_delta volume(actual), 24, 1.0e-7

    for {a, b} <- [{actual, expected}, {expected, actual}] do
      assert_in_delta volume(ok(OCEx.cut(a, b))), 0, 1.0e-7
    end

    ok(OCEx.mesh(actual))
    ok(OCEx.fillet(actual, ok(OCEx.edges(actual)), 0.1))
    assert ok(OCEx.to_brep(source)) == before
  end

  test "every step is validated, including cancelled and malformed transformations" do
    source = ok(OCEx.box(1, 2, 3))

    for steps <- [
          [],
          [:bad],
          [{:scale, [2]}],
          [{:translate, [{1, 2}]}],
          [{:rotate, [{0, 0, 0}, {0, 0, 0}, 0]}]
        ] do
      assert {:error, :invalid_argument} = OCEx.Internal.transform_chain(source, steps)
    end

    actual =
      ok(
        OCEx.Internal.transform_chain(source, [
          {:translate, [{4, 5, 6}]},
          {:translate, [{-4, -5, -6}]}
        ])
      )

    assert_in_delta volume(actual), 6, 1.0e-7
  end
end
