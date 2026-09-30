defmodule Alto.Runner.TaskHostTest do
  use ExUnit.Case, async: true
  alias Alto.Runner.Result
  alias Alto.Runner.TaskHost

  test "a detached handle remains usable after its creator exits" do
    parent = self()

    creator =
      spawn(fn ->
        {:ok, handle} =
          TaskHost.start(
            fn ref ->
              receive do
                {:alto_cancel, ^ref, reason} -> Result.error({:cancelled, reason})
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
    assert %Result{status: :cancelled, reason: :done} = TaskHost.await(handle, 1000)
    assert {:ok, ref} = TaskHost.subscribe(handle)
    assert_receive {:alto_runner_result, ^ref, %Result{status: :cancelled, reason: :done}}
  end

  test "completion can be awaited and observed from independent callers" do
    outcome = %Result{Result.empty() | status: :ok, output: "done", verdict: :completed}
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
            {:alto_cancel, ^cancel_ref, reason} -> Result.error({:cancelled, reason})
          end
        end,
        []
      )

    assert {:error, :await_timeout} = TaskHost.await(handle, 10)
    {:ok, ref} = TaskHost.subscribe(handle)
    assert :ok = TaskHost.cancel(handle, :test)
    assert %Result{status: :cancelled, reason: :test} = TaskHost.await(handle, 1000)
    assert_receive {:alto_runner_result, ^ref, %Result{status: :cancelled, reason: :test}}
    refute_receive {:alto_runner_result, ^ref, _}
  end

  test "a crashed lifecycle host terminates its worker and delivers one terminal notification" do
    {:ok, handle} = TaskHost.start(fn _ -> Process.sleep(:infinity) end, [])
    worker = :sys.get_state(handle.pid).task.pid
    worker_ref = Process.monitor(worker)
    on_exit(fn -> Process.exit(worker, :kill) end)
    {:ok, ref} = TaskHost.subscribe(handle)
    Process.exit(handle.pid, :kill)

    assert_receive {:alto_runner_result, ^ref,
                    %Result{status: :error, reason: {:run_process_failed, :killed}} = result}

    assert result.verdict == :unknown
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 500
    refute_receive {:alto_runner_result, ^ref, _}
  end

  test "dead subscribers release their completion registrations while the run continues" do
    {:ok, handle} = TaskHost.start(fn _ -> Process.sleep(:infinity) end, [])
    on_exit(fn -> TaskHost.terminate(handle) end)
    subscriber = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, _} = TaskHost.subscribe(handle, subscriber)
    assert map_size(:sys.get_state(handle.pid).waiters) == 1
    Process.exit(subscriber, :kill)

    assert Enum.any?(1..100, fn _ ->
             if :sys.get_state(handle.pid).waiters == %{} do
               true
             else
               Process.sleep(5)
               false
             end
           end)

    assert {:error, :await_timeout} = TaskHost.await(handle, 0)
  end

  test "forced termination reports uncertain execution and releases observers" do
    {:ok, handle} = TaskHost.start(fn _ -> Process.sleep(:infinity) end, [])
    {:ok, ref} = TaskHost.subscribe(handle)

    assert %Result{status: :error, reason: {:run_process_failed, :cancel_timeout}} =
             result = TaskHost.terminate(handle)

    assert result.verdict == :unknown

    assert_receive {:alto_runner_result, ^ref,
                    %Result{status: :error, reason: {:run_process_failed, :cancel_timeout}}}
  end

  test "explicit release refuses running work and frees a consumed result host" do
    parent = self()

    {:ok, handle} =
      TaskHost.start(
        fn _ ->
          send(parent, {:worker, self()})

          receive do
            :finish -> Result.empty()
          end
        end,
        []
      )

    assert_receive {:worker, worker}
    assert {:error, :running} = TaskHost.release(handle)
    assert Process.alive?(worker)
    send(worker, :finish)
    assert %Result{} = TaskHost.await(handle, 1000)
    monitor = Process.monitor(handle.pid)
    assert :ok = TaskHost.release(handle)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
  end
end
