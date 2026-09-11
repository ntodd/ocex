ExUnit.start()

defmodule OCEx.TestHelpers do
  import ExUnit.Assertions
  def ok({:ok, value}), do: value
  def volume(shape), do: ok(OCEx.volume(shape))
  def assert_valid(shape), do: assert(OCEx.valid?(shape) == {:ok, true})

  def close_point({a, b, c}, {x, y, z}, tolerance \\ 1.0e-6) do
    assert_in_delta a, x, tolerance
    assert_in_delta b, y, tolerance
    assert_in_delta c, z, tolerance
  end

  def rectangle(w \\ 10, h \\ 20) do
    points = [{0, 0, 0}, {w, 0, 0}, {w, h, 0}, {0, h, 0}, {0, 0, 0}]

    edges =
      points |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> ok(OCEx.edge(a, b)) end)

    ok(OCEx.wire(edges))
  end

  def vertical_edges(body) do
    body
    |> OCEx.edges()
    |> ok()
    |> Enum.filter(fn edge ->
      info = ok(OCEx.edge_info(edge))
      info.type == :line and abs(elem(info.direction, 2)) > 0.999999
    end)
  end
end
