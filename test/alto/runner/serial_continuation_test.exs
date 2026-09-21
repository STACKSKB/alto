defmodule Alto.Runner.SerialContinuationTest do
  use ExUnit.Case, async: true

  alias Alto.{Effect, Event, OperationLog, Transition}
  alias Alto.Subagents.Continuation

  defmodule Parent do
    @behaviour Alto.Loop
    def init(%{agents: agents}, _),
      do: Transition.continue(nil, [Effect.spawn_agents(%{agents: agents})])

    def handle_event(%Event{type: :subagents_completed, data: data}, state, _),
      do: Transition.stop(state, data)

    def handle_event(_, state, _), do: Transition.continue(state)
  end

  defmodule Return do
    @behaviour Alto.Loop
    def init(task, _), do: Transition.stop(nil, task)
    def handle_event(_, state, _), do: Transition.continue(state)
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_, _, opts) do
      [worker | _] = Process.get(:"$callers")
      send(opts[:test_pid], {:child_entered, self(), worker})

      receive do
        :release -> {:ok, %{message: "retained child output", tool_calls: []}}
      end
    end
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-serial-journal-#{System.unique_integer([:positive])}")

    opts = [id: "children", name: nil, dir: dir]
    ledger = start_supervised!({OperationLog, opts})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{ledger: ledger, ledger_opts: opts}
  end

  defp loop(concurrency \\ 2) do
    Alto.loop(Parent,
      subagents:
        Alto.Subagents.bounded(
          max_depth: 1,
          max_children: 4,
          max_concurrency: concurrency
        )
    )
  end

  test "batch results are retained exactly with parent links", %{ledger: ledger} do
    output = %{"text" => "日本語", "nested" => {1, [true, nil]}}

    agents = [
      %{id: "first", task: output, loop: Alto.loop(Return)},
      %{id: "second", task: "second result", loop: Alto.loop(Return)}
    ]

    assert {:ok, result} =
             Alto.run(%{agents: agents}, loop: loop(), continuation_store: ledger)

    assert {:ok, batch} = Continuation.restore(ledger, result.output.journal)
    assert {:ok, joined} = Continuation.join(batch)
    assert Enum.map(joined.results, &elem(&1, 0)) == ["first", "second"]
    assert {"first", retained} = hd(joined.results)
    assert retained.output == output
    assert retained.status == :ok
    assert retained.persistence == :not_requested
    assert joined.metadata["parent_run_id"] == result.run_id
    assert joined.packet["join"] == nil
    assert {:error, :child_already_admitted} = Continuation.dispatch(batch, "first")
  end

  test "cancellation retains queued non-dispatch and the active child's outcome", %{
    ledger: ledger
  } do
    test_pid = self()

    sink = fn
      %Event{type: :subagents_started, data: data} -> send(test_pid, {:journal, data.journal})
      _ -> :ok
    end

    agents = [%{id: "active", task: "a"}, %{id: "queued", task: "b"}]

    assert {:ok, parent} =
             Alto.start(%{agents: agents},
               loop: loop(1),
               continuation_store: ledger,
               provider: {BlockingProvider, test_pid: self()},
               event_sink: sink
             )

    assert_receive {:journal, identity}, 2_000
    assert_receive {:child_entered, _, _}, 2_000
    assert :ok = Alto.cancel(parent, :stop)
    assert {:error, {:cancelled, :stop}, _} = Alto.await(parent, 8_000)
    assert {:ok, batch} = Continuation.restore(ledger, identity)
    assert {:ok, %{results: [{"active", active}, {"queued", queued}]}} = Continuation.join(batch)
    assert active.status == :cancelled
    assert queued.error == {:not_started, {:cancelled, :stop}}
    refute_receive {:child_entered, _, _}, 50
  end

  test "unavailable journal prevents any child callback", %{ledger: ledger} do
    stop_supervised!(OperationLog)

    assert {:error, {:invalid_spawn_agents, {:subagent_journal_unavailable, _}}, _} =
             Alto.run(%{agents: [%{id: "worker", task: "work"}]},
               loop: loop(),
               continuation_store: ledger,
               provider: {BlockingProvider, test_pid: self()}
             )

    refute_receive {:child_entered, _, _}, 50
  end

  test "unportable child output remains uncertain instead of becoming a successful join", %{
    ledger: ledger
  } do
    assert {:error, {:subagent_journal_failed, {:child_pending, "worker", "dispatched"}}, result} =
             Alto.run(%{agents: [%{id: "worker", task: self(), loop: Alto.loop(Return)}]},
               loop: loop(),
               continuation_store: ledger
             )

    assert result.verdict == :unknown
    [key] = OperationLog.keys(ledger)
    assert {:ok, entry} = OperationLog.recovery(ledger, key)

    assert %{"worker" => %{"state" => "dispatched", "result" => nil}} =
             entry.checkpoint["children"]
  end

  test "forced child shutdown preserves cancellation and leaves missing evidence uncertain", %{
    ledger: ledger
  } do
    test_pid = self()

    sink = fn
      %Event{type: :subagents_started, data: data} -> send(test_pid, {:journal, data.journal})
      _ -> :ok
    end

    assert {:ok, parent} =
             Alto.start(%{agents: [%{id: "stuck", task: "work"}]},
               loop: loop(1),
               continuation_store: ledger,
               provider: {BlockingProvider, test_pid: self()},
               event_sink: sink
             )

    assert_receive {:journal, identity}, 2_000
    assert_receive {:child_entered, provider, worker}, 2_000

    on_exit(fn ->
      for pid <- [provider, worker, Alto.Test.Runner.worker(parent)],
          Process.alive?(pid),
          do: Process.exit(pid, :kill)
    end)

    assert :erlang.suspend_process(worker)
    assert :ok = Alto.cancel(parent, :forced_stop)
    assert {:error, {:cancelled, :forced_stop}, result} = Alto.await(parent, 8_000)
    assert result.verdict == :unknown
    assert {:degraded, errors} = result.persistence
    assert {:subagent_journal, {:child_pending, "stuck", "dispatched"}} in errors
    assert {:ok, batch} = Continuation.restore(ledger, identity)
    assert {:error, {:child_pending, "stuck", "dispatched"}} = Continuation.join(batch)
    assert {:error, :child_already_admitted} = Continuation.dispatch(batch, "stuck")
  end
end
