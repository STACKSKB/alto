defmodule Alto.Runner.SerialJournalTest do
  use ExUnit.Case, async: true

  alias Alto.{Effect, Event, OperationLog, Transition}
  alias Alto.Subagents.Journal

  defmodule Parent do
    @behaviour Alto.Loop
    def init(%{agents: agents, single: true}, _),
      do: Transition.continue(nil, [Effect.spawn_agent(hd(agents))])

    def init(%{agents: agents}, _),
      do: Transition.continue(nil, [Effect.spawn_agents(%{agents: agents})])

    def handle_event(%Event{type: type, data: data}, state, _)
        when type in [:subagents_completed, :subagent_completed, :subagent_failed],
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

  defp loop(ledger, concurrency \\ 2) do
    Alto.loop(Parent,
      subagents:
        Alto.Subagents.bounded(
          max_depth: 1,
          max_children: 4,
          max_concurrency: concurrency,
          journal: ledger
        )
    )
  end

  test "single and batch results are retained exactly with parent links", %{ledger: ledger} do
    output = %{"text" => "日本語", "nested" => {1, [true, nil]}}

    agents = [
      %{id: "first", task: output, loop: Alto.loop(Return)},
      %{id: "second", task: "second result", loop: Alto.loop(Return)}
    ]

    for single <- [false, true] do
      assert {:ok, result} = Alto.run(%{agents: agents, single: single}, loop: loop(ledger))
      assert {:ok, batch} = Journal.restore(ledger, result.output.journal)
      assert {:ok, joined} = Journal.join(batch)
      expected_ids = if single, do: ["first"], else: ["first", "second"]
      assert Enum.map(joined.results, &elem(&1, 0)) == expected_ids
      assert {"first", retained} = hd(joined.results)
      assert retained.output == output
      assert retained.status == :ok
      assert retained.persistence == :not_requested
      assert joined.packet["metadata"]["parent_run_id"] == result.run_id
      assert joined.packet["join"] == nil
      assert {:error, :child_already_admitted} = Journal.dispatch(batch, "first")
    end
  end

  test "a child saves its result even while the parent cannot collect it", %{
    ledger: ledger,
    ledger_opts: ledger_opts
  } do
    test_pid = self()

    sink = fn
      %Event{type: :subagents_started, data: data} -> send(test_pid, {:journal, data.journal})
      _ -> :ok
    end

    assert {:ok, parent} =
             Alto.start(%{agents: [%{id: "worker", task: "work"}]},
               loop: loop(ledger, 1),
               provider: {BlockingProvider, test_pid: self()},
               event_sink: sink
             )

    on_exit(fn ->
      if Process.alive?(parent.task.pid), do: Process.exit(parent.task.pid, :kill)
    end)

    assert_receive {:journal, identity}, 2_000
    assert_receive {:child_entered, provider, worker}, 2_000
    monitor = Process.monitor(worker)
    assert :erlang.suspend_process(parent.task.pid)
    send(provider, :release)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert {:ok, batch} = Journal.restore(ledger, identity)
    assert {:ok, %{results: [{"worker", saved}]}} = Journal.join(batch)
    assert saved.output == "retained child output"
    assert saved.model_requests == 1

    parent_monitor = Process.monitor(parent.task.pid)
    Process.exit(parent.task.pid, :kill)
    assert_receive {:DOWN, ^parent_monitor, :process, _, :killed}, 2_000
    stop_supervised!(OperationLog)
    restarted = start_supervised!({OperationLog, ledger_opts})
    assert {:ok, restored} = Journal.restore(restarted, identity)
    assert {:ok, %{results: [{"worker", ^saved}]}} = Journal.join(restored)
    assert {:error, :child_already_admitted} = Journal.dispatch(restored, "worker")
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
               loop: loop(ledger, 1),
               provider: {BlockingProvider, test_pid: self()},
               event_sink: sink
             )

    assert_receive {:journal, identity}, 2_000
    assert_receive {:child_entered, _, _}, 2_000
    assert :ok = Alto.cancel(parent, :stop)
    assert {:error, {:cancelled, :stop}, _} = Alto.await(parent, 8_000)
    assert {:ok, batch} = Journal.restore(ledger, identity)
    assert {:ok, %{results: [{"active", active}, {"queued", queued}]}} = Journal.join(batch)
    assert active.status == :cancelled
    assert queued.error == {:not_started, {:cancelled, :stop}}
    refute_receive {:child_entered, _, _}, 50
  end

  test "unavailable journal prevents any child callback", %{ledger: ledger} do
    stop_supervised!(OperationLog)

    assert {:error, {:invalid_spawn_agents, {:subagent_journal_unavailable, _}}, _} =
             Alto.run(%{agents: [%{id: "worker", task: "work"}]},
               loop: loop(ledger),
               provider: {BlockingProvider, test_pid: self()}
             )

    refute_receive {:child_entered, _, _}, 50
  end

  test "unportable child output remains uncertain instead of becoming a successful join", %{
    ledger: ledger
  } do
    assert {:error, {:subagent_journal_failed, {:child_pending, "worker", "dispatched"}}, result} =
             Alto.run(%{agents: [%{id: "worker", task: self(), loop: Alto.loop(Return)}]},
               loop: loop(ledger)
             )

    assert result.verdict == :unknown
    [key] = OperationLog.keys(ledger)
    assert {:ok, entry} = OperationLog.recovery(ledger, key)
    assert [%{"state" => "dispatched", "result" => nil}] = entry.checkpoint["children"]
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
               loop: loop(ledger, 1),
               provider: {BlockingProvider, test_pid: self()},
               event_sink: sink
             )

    assert_receive {:journal, identity}, 2_000
    assert_receive {:child_entered, provider, worker}, 2_000

    on_exit(fn ->
      for pid <- [provider, worker, parent.task.pid],
          Process.alive?(pid),
          do: Process.exit(pid, :kill)
    end)

    assert :erlang.suspend_process(worker)
    assert :ok = Alto.cancel(parent, :forced_stop)
    assert {:error, {:cancelled, :forced_stop}, result} = Alto.await(parent, 8_000)
    assert result.verdict == :unknown
    assert {:degraded, errors} = result.persistence
    assert {:subagent_journal, {:child_pending, "stuck", "dispatched"}} in errors
    assert {:ok, batch} = Journal.restore(ledger, identity)
    assert {:error, {:child_pending, "stuck", "dispatched"}} = Journal.join(batch)
    assert {:error, :child_already_admitted} = Journal.dispatch(batch, "stuck")
  end
end
