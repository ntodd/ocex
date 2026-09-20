defmodule OCEx.BooleanBatchTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  test "batched cuts subtract overlapping tools once and preserve inputs" do
    body = ok(OCEx.box(10, 10, 10))
    a = ok(OCEx.box(4, 10, 12)) |> OCEx.translate({1, 0, -1}) |> ok()
    b = ok(OCEx.box(4, 10, 12)) |> OCEx.translate({3, 0, -1}) |> ok()
    before = Enum.map([body, a, b], &ok(OCEx.to_brep(&1)))
    result = ok(OCEx.cut_many(body, [a, b]))
    assert_valid(result)
    assert_in_delta volume(result), 400, 1.0e-7
    assert length(ok(OCEx.solids(result))) == 2
    assert Enum.map([body, a, b], &ok(OCEx.to_brep(&1))) == before
    assert_in_delta volume(ok(OCEx.cut_many(body, [body]))), 0, 1.0e-7
  end

  test "batched fusions handle intersecting and disjoint tools" do
    body = ok(OCEx.box(10, 10, 10))
    a = ok(OCEx.translate(body, {5, 0, 0}))
    b = ok(OCEx.translate(body, {8, 0, 0}))
    c = ok(OCEx.translate(body, {30, 0, 0}))
    result = ok(OCEx.fuse_many(body, [a, b, c]))
    assert_valid(result)
    assert_in_delta volume(result), 2800, 1.0e-7
    assert length(ok(OCEx.solids(result))) == 2
    assert_in_delta volume(ok(OCEx.fuse_many(body, [body, body]))), 1000, 1.0e-7
  end

  test "batched operations reject empty and malformed tool lists" do
    body = ok(OCEx.box(2, 3, 4))

    for op <- [:cut_many, :fuse_many], tools <- [[], nil, [nil], [body | :bad]] do
      assert {:error, :invalid_argument} = apply(OCEx, op, [body, tools])
    end
  end

  test "large-topology batches remain valid and immutable under repeated calls" do
    unit = ok(OCEx.box(1, 1, 1))
    pieces = for i <- 0..23, do: ok(OCEx.translate(unit, {i * 2, 0, 0}))
    body = ok(OCEx.compound(pieces))

    tools =
      for i <- 0..2,
          do: ok(OCEx.cylinder(0.2, 3)) |> OCEx.translate({i * 2 + 0.5, 0.5, -1}) |> ok()

    before = Enum.map([body | tools], &ok(OCEx.to_brep(&1)))

    for _ <- 1..3 do
      result = ok(OCEx.cut_many(body, tools))
      assert_valid(result)
      assert_in_delta volume(result), 24 - 0.12 * :math.pi(), 1.0e-7
    end

    assert Enum.map([body | tools], &ok(OCEx.to_brep(&1))) == before
  end

  test "concurrent batches retain source and result independence" do
    body = ok(OCEx.box(10, 10, 10))
    tool = ok(OCEx.box(2, 2, 12)) |> OCEx.translate({4, 4, -1}) |> ok()
    original = ok(OCEx.to_brep(body))
    tool_brep = ok(OCEx.to_brep(tool))

    results =
      Task.async_stream(
        1..12,
        fn _ ->
          result = ok(OCEx.cut_many(body, [tool]))
          assert_valid(result)
          ok(OCEx.mesh(result))
          assert_in_delta volume(result), 960, 1.0e-7
          ok(OCEx.to_brep(result))
        end,
        max_concurrency: 4
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert ok(OCEx.to_brep(body)) == original
    assert ok(OCEx.to_brep(tool)) == tool_brep
  end

  test "repeated volume queries stay accurate across copies, meshing, and concurrent reads" do
    body = ok(OCEx.box(2, 3, 4))
    original_volume = volume(body)
    assert_in_delta original_volume, 24.0, 1.0e-10
    scaled = ok(OCEx.scale(body, 2))
    scaled_volume = volume(scaled)
    assert_in_delta scaled_volume, 192.0, 1.0e-10
    ok(OCEx.mesh(body))
    restored = body |> OCEx.to_brep() |> ok() |> OCEx.from_brep() |> ok()
    assert_in_delta volume(restored), 24.0, 1.0e-10

    results =
      Task.async_stream(1..20, fn _ -> {volume(body), volume(scaled)} end) |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, {original_volume, scaled_volume}}))
    assert volume(body) == original_volume
  end
end
