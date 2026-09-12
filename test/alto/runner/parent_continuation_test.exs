defmodule Alto.Runner.ParentContinuationTest do
  use ExUnit.Case, async: false

  alias Alto.{Effect, Event, OperationLog, Transition}
  alias Alto.Runner.Budget.Account
  alias Alto.Subagents.{Continuation, Journal}

  defmodule ParentLoop do
    @behaviour Alto.Loop

    def init(%{agents: agents}, _spec),
      do: Transition.continue(%{phase: "children"}, [Effect.spawn_agents(%{agents: agents})])

    def handle_event(%Event{type: :subagents_completed, data: %{results: results}}, state, _spec) do
      call = %{id: "integrate-1", name: "integrate", arguments: %{"value" => "joined"}}
      Transition.continue(Map.put(state, :results, results), [Effect.invoke_tool(call)])
    end

    def handle_event(%Event{type: :tool_completed, data: data}, state, _spec),
      do: Transition.stop(state, %{results: state.results, tool: data})

    def handle_event(_event, state, _spec), do: Transition.continue(state)

    def dump_checkpoint(state, _spec), do: {:ok, state}
    def load_checkpoint(state, _spec), do: {:ok, state}
  end

  defmodule ReturnLoop do
    @behaviour Alto.Loop
    def init(task, _spec), do: Transition.stop(nil, task)
    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  defmodule IntegrateTool do
    @behaviour Alto.Tool
    def name, do: :integrate

    def schema,
      do: %{
        description: "Record one parent integration.",
        parameters: %{
          type: "object",
          properties: %{value: %{type: "string"}},
          required: ["value"]
        }
      }

    def execution_mode, do: :exclusive
    def approval, do: :never

    def run(%{"value" => value}, _context) do
      send(:persistent_term.get({__MODULE__, :observer}), {:integrated, value})
      {:ok, %{integrated: value}}
    end
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_, _, opts) do
      [worker | _] = Process.get(:"$callers")
      send(Keyword.fetch!(opts, :test_pid), {:child_entered, self(), worker})

      receive do
        :release -> {:ok, %{message: "retained output", tool_calls: []}}
      end
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-parent-live-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    :persistent_term.put({IntegrateTool, :observer}, self())
    on_exit(fn -> :persistent_term.erase({IntegrateTool, :observer}) end)
    %{dir: dir}
  end

  defp ledgers(dir, suffix) do
    parent =
      start_supervised!(
        {OperationLog,
         id: "parents-#{suffix}",
         name: nil,
         dir: dir,
         max_recovery_bytes: 2_200_000,
         max_record_bytes: 3_000_000},
        id: {:parent_ledger, suffix}
      )

    children =
      start_supervised!({OperationLog, id: "children-#{suffix}", name: nil, dir: dir},
        id: {:child_ledger, suffix}
      )

    budget =
      start_supervised!({OperationLog, id: "budget-#{suffix}", name: nil, dir: dir},
        id: {:budget_ledger, suffix}
      )

    {:ok, account} =
      Account.open(budget, "account", max_effects: 50, max_model_requests: 20)

    %{parent: parent, children: children, budget: budget, account: account}
  end

  defp restart_ledgers(dir, suffix) do
    stop_supervised!({:parent_ledger, suffix})
    stop_supervised!({:child_ledger, suffix})
    stop_supervised!({:budget_ledger, suffix})
    ledgers(dir, suffix)
  end

  defp opts(ledgers, dir, runner, extra \\ []) do
    base = [
      runner: runner,
      loop:
        Alto.loop(ParentLoop,
          subagents:
            Alto.Subagents.bounded(
              max_depth: 1,
              max_children: 4,
              max_concurrency: 1,
              journal: ledgers.children
            )
        ),
      tools: [IntegrateTool],
      continuation_store: ledgers.parent,
      continuation_key: "trusted-parent",
      checkpoint_version: "v1",
      budget_account: ledgers.account,
      max_effects: 50,
      max_model_requests: 20,
      run_timeout: 20_000,
      session: :new,
      session_dir: dir
    ]

    Keyword.merge(base, extra)
  end

  defp only_cell!(parent) do
    [key] = OperationLog.keys(parent)
    {:ok, entry} = OperationLog.recovery(parent, key)
    identity = %{"key" => key, "generation" => entry.recovery["generation"]}
    {:ok, cell} = Continuation.restore(parent, identity)
    {cell, identity}
  end

  test "both schedulers run a retained parent boundary and claim its frame once", %{dir: dir} do
    for runner <- [Alto.Runner.Serial, Alto.Runner.Stepped] do
      suffix = if runner == Alto.Runner.Serial, do: "serial", else: "stepped"
      ledgers = ledgers(dir, suffix)

      agents = [
        %{id: "first", task: "one", loop: Alto.loop(ReturnLoop)},
        %{id: "second", task: "two", loop: Alto.loop(ReturnLoop)}
      ]

      assert {:ok, result} = Alto.run(%{agents: agents}, opts(ledgers, dir, runner))
      assert Enum.map(result.output.results, & &1.id) == ["first", "second"]
      assert_receive {:integrated, "joined"}, 2_000
      refute_receive {:integrated, _}, 50

      {cell, identity} = only_cell!(ledgers.parent)
      assert {:ok, %{phase: :claimed}} = Continuation.read(cell)

      assert {:error, :continuation_already_claimed} =
               Continuation.claim(cell, elem(Continuation.read(cell), 1).revision)

      assert {:error, :continuation_already_claimed, _} =
               Alto.run(:ignored, opts(ledgers, dir, runner, continuation: identity))

      [child_key] = OperationLog.keys(ledgers.children)
      {:ok, child_entry} = OperationLog.recovery(ledgers.children, child_key)

      {:ok, journal} =
        Journal.restore(ledgers.children, %{
          "key" => child_key,
          "generation" => child_entry.recovery["generation"]
        })

      assert {:ok, %{packet: %{"join" => receipt}}} = Journal.read(journal)
      assert receipt["continuation"] == identity
    end
  end

  test "a completed child result is joined after parent kill without rerunning it", %{dir: dir} do
    ledgers = ledgers(dir, "crash")
    test_pid = self()

    sink = fn
      %Event{type: :subagents_started, data: data} -> send(test_pid, {:journal, data.journal})
      _ -> :ok
    end

    run_opts =
      opts(ledgers, dir, Alto.Runner.Serial,
        provider: {BlockingProvider, test_pid: self()},
        event_sink: sink
      )

    assert {:ok, parent} = Alto.start(%{agents: [%{id: "worker", task: "work"}]}, run_opts)
    assert_receive {:journal, journal_identity}, 2_000
    assert_receive {:child_entered, provider, worker}, 2_000
    parent_worker = Alto.Test.Runner.worker(parent)
    assert :erlang.suspend_process(parent_worker)
    child_monitor = Process.monitor(worker)
    send(provider, :release)
    assert_receive {:DOWN, ^child_monitor, :process, ^worker, :normal}, 2_000
    assert {:ok, journal} = Journal.restore(ledgers.children, journal_identity)
    assert {:ok, %{results: [{"worker", saved}]}} = Journal.join(journal)
    assert saved.output == "retained output"
    assert saved.model_requests == 1

    {cell, identity} = only_cell!(ledgers.parent)
    assert {:ok, %{phase: :pending}} = Continuation.read(cell)
    parent_monitor = Process.monitor(parent_worker)
    Process.exit(parent_worker, :kill)
    assert_receive {:DOWN, ^parent_monitor, :process, ^parent_worker, :killed}, 2_000

    ledgers = restart_ledgers(dir, "crash")

    run_opts =
      opts(ledgers, dir, Alto.Runner.Serial,
        provider: {BlockingProvider, test_pid: self()},
        event_sink: sink
      )

    {:ok, cell} = Continuation.restore(ledgers.parent, identity)
    assert {:ok, %{phase: :pending}} = Continuation.read(cell)
    {:ok, journal} = Journal.restore(ledgers.children, journal_identity)
    assert {:ok, %{results: [{"worker", ^saved}]}} = Journal.join(journal)

    assert {:ok, result} = Alto.run(:ignored, Keyword.put(run_opts, :continuation, identity))
    assert [%{id: "worker", output: "retained output"}] = result.output.results
    assert_receive {:integrated, "joined"}, 2_000
    refute_receive {:child_entered, _, _}, 50
    refute_receive {:integrated, _}, 50
    assert {:ok, %{phase: :claimed}} = Continuation.read(cell)

    assert {:error, :continuation_already_claimed, _} =
             Alto.run(:ignored, Keyword.put(run_opts, :continuation, identity))

    assert {:ok, counts} = Account.read(ledgers.account)
    assert counts.packet["model_requests_used"] == 1
  end

  test "an incomplete dispatched child stays pending across resume", %{dir: dir} do
    ledgers = ledgers(dir, "incomplete")
    test_pid = self()

    sink = fn
      %Event{type: :subagents_started, data: data} -> send(test_pid, {:journal, data.journal})
      _ -> :ok
    end

    run_opts =
      opts(ledgers, dir, Alto.Runner.Serial,
        provider: {BlockingProvider, test_pid: self()},
        event_sink: sink
      )

    assert {:ok, parent} = Alto.start(%{agents: [%{id: "worker", task: "work"}]}, run_opts)
    assert_receive {:journal, journal_identity}, 2_000
    assert_receive {:child_entered, provider, worker}, 2_000
    {cell, identity} = only_cell!(ledgers.parent)
    assert {:ok, %{phase: :pending} = pending} = Continuation.read(cell)
    parent_worker = Alto.Test.Runner.worker(parent)
    parent_monitor = Process.monitor(parent_worker)
    Process.exit(parent_worker, :kill)
    assert_receive {:DOWN, ^parent_monitor, :process, ^parent_worker, :killed}, 2_000
    for pid <- [provider, worker], Process.alive?(pid), do: Process.exit(pid, :kill)

    assert {:error, {:children_pending, {:child_pending, "worker", "dispatched"}}, result} =
             Alto.run(:ignored, Keyword.put(run_opts, :continuation, identity))

    assert result.checkpoint["continuation"] == identity
    assert Continuation.read(cell) == {:ok, pending}
    assert {:ok, journal} = Journal.restore(ledgers.children, journal_identity)
    assert {:error, {:child_pending, "worker", "dispatched"}} = Journal.join(journal)
    assert {:error, :child_already_admitted} = Journal.dispatch(journal, "worker")
    refute_receive {:child_entered, _, _}, 50
    refute_receive {:integrated, _}, 50
  end
end
