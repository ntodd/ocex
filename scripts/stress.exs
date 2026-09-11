# A separate BEAM invocation makes native crashes observable as command failure.
# Run via `make stress`.
defmodule Stress do
  def ok({:ok, value}), do: value
  def count, do: ok(OCEx.Native.call(:resource_count, []))
end
baseline = Stress.count()
for batch <- 1..20 do
  task = Task.async(fn ->
    for i <- 1..50 do
      body = Stress.ok(OCEx.box(10, 20, 30))
      shifted = Stress.ok(OCEx.translate(body, {i, 0, 0}))
      {:ok, true} = OCEx.valid?(shifted)
      {:ok, volume} = OCEx.volume(shifted)
      if abs(volume - 6000) > 1.0e-6, do: raise("invalid stress geometry")
      {:ok, edges} = OCEx.edges(shifted)
      for edge <- edges, do: Stress.ok(OCEx.edge_info(edge))
      if rem(i, 10) == 0, do: Stress.ok(OCEx.mesh(shifted))
      for malformed <- [nil, [], %{}, make_ref(), [1 | 2], <<0, 255>>] do
        {:error, _} = OCEx.Native.call(:box, malformed)
        {:error, _} = OCEx.Native.call(:volume, [malformed])
      end
    end
    :done
  end)
  :done = Task.await(task, 30_000)
  :erlang.garbage_collect()
  # Resource destruction can finish just after the process exit signal.
  Enum.reduce_while(1..100, nil, fn _, _ ->
    if Stress.count() <= baseline, do: {:halt, nil}, else: (Process.sleep(10); {:cont, nil})
  end)
  if Stress.count() > baseline, do: raise("native resources leaked in batch #{batch}")
end
IO.puts("Stress passed: 1,000 shape workloads, 100 meshes, 12,000 malformed calls; native resources returned to baseline.")
