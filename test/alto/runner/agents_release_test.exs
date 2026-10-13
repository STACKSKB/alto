defmodule Alto.Runner.AgentsReleaseTest do
  use ExUnit.Case, async: true

  alias Alto.Runner.Agents
  alias Alto.Runner.Handle
  alias Alto.Runner.Result
  alias Alto.Runner.TaskHost

  defmodule FailedSubscriptionRunner do
    def subscribe(_, _), do: {:error, :subscription_unavailable}
    def terminate(handle, reason), do: TaskHost.terminate(handle, reason)
    def release(handle), do: TaskHost.release(handle)
  end

  defmodule NoReleaseRunner do
    def subscribe(handle, subscriber) do
      ref = make_ref()
      send(subscriber, {:alto_runner_result, ref, handle})
      {:ok, ref}
    end
  end

  test "completed child hosts exit after their batch results are consumed" do
    owner = self()
    checkpoint = %{"kind" => "child", "state" => %{"step" => 1}}

    outcome = %Result{
      Result.empty()
      | status: :suspended,
        reason: :execution_suspended,
        checkpoint: checkpoint
    }

    start = fn _ ->
      {:ok, host} = TaskHost.start(fn _ -> outcome end, [])
      send(owner, {:child_host, host.pid})
      {:ok, %Handle{runner: Alto.Runner.Serial, state: host}}
    end

    assert {:ok, [{"child", ^outcome}]} =
             Agents.batch([%{id: "child"}], 1, start, fn -> :continue end)

    assert_receive {:child_host, host_pid}
    refute Process.alive?(host_pid)
  end

  test "cancellation and scheduler failure both release the child host" do
    owner = self()
    outcome = %Result{Result.empty() | status: :cancelled, reason: :operator}

    start = fn _ ->
      {:ok, host} =
        TaskHost.start(
          fn _ ->
            send(owner, :child_running)

            receive do
              {:alto_cancel, _, _} -> outcome
            end
          end,
          []
        )

      send(owner, {:child_host, host.pid})
      {:ok, %Handle{runner: Alto.Runner.Serial, state: host}}
    end

    for {signal, expected} <- [
          {:cancel, {{:cancelled, :operator}, [{"child", outcome}]}},
          {:fail, :scheduler_failed}
        ] do
      batch =
        Task.async(fn ->
          check = fn ->
            receive do
              :cancel -> {:cancelled, :operator}
              :fail -> exit(:scheduler_failed)
            after
              0 -> :continue
            end
          end

          try do
            Agents.batch([%{id: "child"}], 1, start, check)
          catch
            :exit, reason -> reason
          end
        end)

      assert_receive {:child_host, host_pid}, 2_000
      assert_receive :child_running, 2_000
      send(batch.pid, signal)

      assert Task.await(batch, 7_000) == expected
      refute Process.alive?(host_pid)
    end
  end

  test "subscription failure releases the terminated child host" do
    owner = self()

    start = fn _ ->
      {:ok, host} = TaskHost.start(fn _ -> Process.sleep(:infinity) end, [])
      send(owner, {:child_host, host.pid})
      {:ok, host}
    end

    assert {:ok, [{"child", %Result{status: :error}}]} =
             Agents.batch([%{id: "child"}], 1, start, fn -> :continue end,
               runner: FailedSubscriptionRunner
             )

    assert_receive {:child_host, host_pid}
    refute Process.alive?(host_pid)
  end

  test "a custom runner without release still returns its child outcome" do
    outcome = %Result{Result.empty() | status: :ok, output: "custom"}

    assert {:ok, [{"child", ^outcome}]} =
             Agents.batch([%{id: "child"}], 1, fn _ -> {:ok, outcome} end, fn -> :continue end,
               runner: NoReleaseRunner
             )
  end
end
