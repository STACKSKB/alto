defmodule Alto.Runner.TaskHostTest do
  use ExUnit.Case, async: true
  alias Alto.Runner.{Result, TaskHost}

  test "a detached handle remains usable after its creator exits" do
    parent = self()

    creator =
      spawn(fn ->
        {:ok, handle} =
          TaskHost.start(
            fn ref ->
              receive do
                {:alto_cancel, ^ref, reason} -> {:error, {:cancelled, reason}, Result.empty()}
              end
            end,
            []
          )

        send(parent, {:detached, handle})
      end)

    monitor = Process.monitor(creator)
    assert_receive {:detached, handle}
    assert_receive {:DOWN, ^monitor, :process, ^creator, _}
    assert :ok = TaskHost.cancel(handle, :done)
    assert {:error, {:cancelled, :done}, _} = TaskHost.await(handle, 1000)
    assert {:ok, ref} = TaskHost.subscribe(handle)
    assert_receive {:alto_runner_result, ^ref, {:error, {:cancelled, :done}, _}}
  end

  test "completion can be awaited and observed from independent callers" do
    outcome = {:ok, %{Result.empty() | output: "done", verdict: :completed}}
    {:ok, handle} = TaskHost.start(fn _ -> outcome end, [])
    assert ^outcome = TaskHost.await(handle, 1000)
    parent = self()
    spawn(fn -> send(parent, {:observed, TaskHost.subscribe(handle, parent)}) end)
    assert_receive {:observed, {:ok, ref}}
    assert_receive {:alto_runner_result, ^ref, ^outcome}
    assert ^outcome = TaskHost.await(handle, 0)
  end

  test "a timed out wait does not consume the result or cancel execution" do
    {:ok, handle} =
      TaskHost.start(
        fn cancel_ref ->
          receive do
            {:alto_cancel, ^cancel_ref, reason} -> {:error, {:cancelled, reason}, Result.empty()}
          end
        end,
        []
      )

    assert {:error, :await_timeout} = TaskHost.await(handle, 10)
    {:ok, ref} = TaskHost.subscribe(handle)
    assert :ok = TaskHost.cancel(handle, :test)
    assert {:error, {:cancelled, :test}, _} = TaskHost.await(handle, 1000)
    assert_receive {:alto_runner_result, ^ref, {:error, {:cancelled, :test}, _}}
    refute_receive {:alto_runner_result, ^ref, _}
  end

  test "a crashed lifecycle host still delivers one terminal notification" do
    {:ok, handle} = TaskHost.start(fn _ -> Process.sleep(:infinity) end, [])
    {:ok, ref} = TaskHost.subscribe(handle)
    Process.exit(handle.pid, :kill)
    assert_receive {:alto_runner_result, ^ref, {:error, {:run_process_failed, :killed}, result}}
    assert result.verdict == :unknown
    refute_receive {:alto_runner_result, ^ref, _}
  end

  test "forced termination reports uncertain execution and releases observers" do
    {:ok, handle} = TaskHost.start(fn _ -> Process.sleep(:infinity) end, [])
    {:ok, ref} = TaskHost.subscribe(handle)
    assert {:error, {:run_process_failed, :cancel_timeout}, result} = TaskHost.terminate(handle)
    assert result.verdict == :unknown

    assert_receive {:alto_runner_result, ^ref,
                    {:error, {:run_process_failed, :cancel_timeout}, _}}
  end
end
