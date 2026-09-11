defmodule OCEx.RuntimeTest do
  use ExUnit.Case, async: false
  import OCEx.TestHelpers

  test "all native resources are released after their owning process exits" do
    baseline = ok(OCEx.Native.call(:resource_count, []))
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        resources =
          for _ <- 1..100 do
            body = ok(OCEx.box(10, 20, 30))
            {body, ok(OCEx.faces(body)), ok(OCEx.edges(body))}
          end

        send(parent, {:allocated, ok(OCEx.Native.call(:resource_count, []))})

        receive do
          :finish -> assert length(resources) == 100
        end
      end)

    assert_receive {:allocated, count}, 5_000
    assert count >= baseline + 1900
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    assert eventually(fn -> ok(OCEx.Native.call(:resource_count, [])) <= baseline end)
  end

  test "native workload leaves the ordinary scheduler responsive" do
    parent = self()

    worker =
      Task.async(fn ->
        send(parent, :started)

        for _ <- 1..12 do
          sphere = ok(OCEx.sphere(10))
          ok(OCEx.mesh(sphere, 0.005))
        end
      end)

    assert_receive :started

    latencies =
      for _ <- 1..30 do
        start = System.monotonic_time(:millisecond)
        Process.sleep(5)
        System.monotonic_time(:millisecond) - start
      end

    Task.await(worker, 30_000)
    assert Enum.max(latencies) < 500
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: check.()

  defp eventually(check, attempts) do
    if check.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(check, attempts - 1)
        )
  end
end
