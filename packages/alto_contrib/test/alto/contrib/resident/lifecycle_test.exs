defmodule Alto.Contrib.Resident.LifecycleTest do
  use ExUnit.Case, async: false

  alias Alto.{Event, OperationLog}
  alias Alto.Runner.Budget.Account
  alias Alto.Subagents.Continuation
  alias Alto.Contrib.Resident.{Config, Lifecycle, ParentRuns, Service, Tasks}

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, _opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")),
        do: {:ok, %{message: "done", tool_calls: []}},
        else: {:ok, %{message: "child", tool_calls: []}}
    end
  end

  defmodule ParentLoop do
    @behaviour Alto.Loop

    def init(_task, _spec),
      do: {:continue, %{}, [{:spawn_agents, %{agents: [%{id: "child", task: "work"}]}}]}

    def handle_event(%Event{type: :subagents_completed, data: %{results: results}}, state, _spec),
      do:
        {:continue, Map.put(state, :results, results),
         [
           {:invoke_tool, %{id: "integrate", name: "integrate", arguments: %{}}}
         ]}

    def handle_event(%Event{type: :tool_completed}, state, _spec),
      do: {{:stop, :done}, state, []}

    def handle_event(_event, state, _spec), do: {:continue, state, []}
    def dump_checkpoint(state, _spec), do: {:ok, state}
    def load_checkpoint(state, _spec), do: {:ok, state}
  end

  defmodule Integrate do
    @behaviour Alto.Tool
    def name(_opts), do: :integrate

    def schema(_opts),
      do: %{description: "integrate", parameters: %{type: "object", properties: %{}}}

    def execution_mode(_opts), do: :exclusive
    def approval(_opts), do: :never
    def run(_, _, _opts), do: {:ok, "integrated"}
  end

  defmodule Echo do
    @behaviour Alto.Loop
    def init(task, _spec), do: {{:stop, task}, task, []}
    def handle_event(_, state, _spec), do: {:continue, state, []}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "zek-lifecycle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    name = make_ref()

    profile =
      Alto.Config.default(
        provider: {Provider, []},
        loop:
          Alto.loop(ParentLoop,
            subagents:
              Alto.Subagents.bounded(
                max_depth: 1,
                max_children: 1,
                max_concurrency: 1
              )
          ),
        tools: [Integrate],
        continuation_store: ParentRuns.ledger(name),
        checkpoint_version: "lifecycle-v1",
        max_effects: 20,
        max_model_requests: 20
      )

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        scheduling: [workers: 1, poll_ms: 10, run_timeout: 10_000],
        profiles: %{
          "parent" => profile,
          "echo" => Alto.Config.default(provider: nil, loop: Alto.loop(Echo))
        }
      )

    start_supervised!({Service, config: config, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: name, config: config}
  end

  test "terminal cleanup is idempotent", %{name: name} do
    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "done",
               "profile" => "parent",
               "task" => "work"
             })

    task = eventually(name, "done", "completed")

    assert {:ok, %{status: "cleaned"}} =
             Tasks.command(name, "cleanup", %{"id" => "done", "revision" => task["revision"]})

    assert {:ok, %{status: "cleaned"}} =
             Tasks.command(name, "cleanup", %{"id" => "done", "revision" => task["revision"]})
  end

  test "ordinary terminal cleanup is idempotent", %{name: name} do
    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "ordinary-done",
               "profile" => "echo",
               "task" => "work"
             })

    task = eventually(name, "ordinary-done", "completed")

    assert {:ok, %{status: "cleaned", resources: 0}} =
             Tasks.command(name, "cleanup", %{
               "id" => "ordinary-done",
               "revision" => task["revision"]
             })

    assert {:ok, %{status: "cleaned", resources: 0}} =
             Tasks.command(name, "cleanup", %{
               "id" => "ordinary-done",
               "revision" => task["revision"]
             })

    assert {:error, :stale_revision} =
             Tasks.command(name, "cleanup", %{
               "id" => "ordinary-done",
               "revision" => task["revision"] + 1
             })
  end

  test "explicit nil budget account is treated as task-owned", %{name: name, config: config} do
    profile = config.profiles["parent"]
    nil_budget = Alto.Config.default(Keyword.put(profile, :budget_account, nil))
    config = %{config | profiles: Map.put(config.profiles, "nil-budget", nil_budget)}
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "nil-budget",
               "profile" => "nil-budget",
               "task" => "work"
             })

    task = eventually(name, "nil-budget", "completed")

    {:ok, entry} = OperationLog.request(ParentRuns.budgets(name), {:recovery, "task:nil-budget"})

    account = %Alto.Persistence.Retained{
      kind: Account,
      ledger: ParentRuns.budgets(name),
      key: "task:nil-budget",
      generation: entry.recovery["generation"]
    }

    assert {:ok, %{state: :active}} = Account.read(account)

    assert {:ok, %{status: "cleaned", resources: 3}} =
             Tasks.command(name, "cleanup", %{
               "id" => "nil-budget",
               "revision" => task["revision"]
             })

    assert {:ok, %{state: :retired}} = Account.read(account)
  end

  test "cleanup refuses running, pending, and stale tasks", %{name: name} do
    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "pending",
               "profile" => "parent",
               "task" => "work",
               "delay_ms" => 60_000
             })

    assert {:error, :task_not_terminal} =
             Tasks.command(name, "cleanup", %{"id" => "pending", "revision" => 1})

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "running",
               "profile" => "parent",
               "task" => "work"
             })

    assert {:error, :task_not_terminal} =
             Tasks.command(name, "cleanup", %{"id" => "running", "revision" => 1})

    task = eventually(name, "running", "completed")

    assert {:error, :stale_revision} =
             Tasks.command(name, "cleanup", %{
               "id" => "running",
               "revision" => task["revision"] + 1
             })
  end

  test "interrupted cleanup resumes after task record eviction", %{name: name, config: config} do
    config = restart_with_one_task!(name, config)
    resources = parent_resources!(name, "interrupted", :claimed)
    terminal = terminal_task!(name, "interrupted", "generation-one")
    {key, _plan} = manifest!(name, terminal, resources)
    assert :ok = OperationLog.request(Lifecycle.ledger(name), {:attempt, key, "retire-resources"})
    {:ok, cell} = Continuation.read(resources.cell)
    assert :ok = Continuation.retire(resources.cell, cell.revision)

    _ = terminal_task!(name, "evict-task", "generation-two")

    assert {:error, :not_found} =
             OperationLog.request(Service.component(name, :ledger), {:recovery, "interrupted"})

    assert {:error, :cleanup_plan_not_found} =
             Lifecycle.resume(config, name, "interrupted", terminal.revision + 1)

    assert {:ok, %{task_id: "interrupted", status: "cleaned", resources: 3}} =
             Tasks.command(name, "cleanup", %{
               "id" => "interrupted",
               "revision" => terminal.revision
             })

    assert {:ok, %{state: :retired}} = Continuation.read(resources.cell)
    assert {:ok, %{state: :retired}} = Account.read(resources.account)

    assert {:ok, %{status: {:decided, :completed, _}}} =
             OperationLog.request(Lifecycle.ledger(name), {:recovery, key})

    assert {:ok, %{status: "cleaned"}} =
             Tasks.command(name, "cleanup", %{
               "id" => "interrupted",
               "revision" => terminal.revision
             })
  end

  test "cleanup and resume fence changed plan identity", %{name: name, config: config} do
    resources = parent_resources!(name, "fenced", :claimed)
    terminal = terminal_task!(name, "fenced", "generation-fenced")
    _ = manifest!(name, terminal, resources)

    assert {:error, :cleanup_plan_mismatch} =
             Lifecycle.cleanup(config, name, %{terminal | revision: terminal.revision + 1})

    profile = config.profiles["parent"]

    changed =
      Alto.Config.default(Keyword.put(profile, :continuation_store, ParentRuns.budgets(name)))

    changed_config = %{config | profiles: Map.put(config.profiles, "parent", changed)}

    assert {:error, :cleanup_plan_mismatch} =
             Lifecycle.resume(changed_config, name, "fenced", terminal.revision)

    assert {:ok, %{state: :active}} = Continuation.read(resources.cell)
    assert {:ok, %{state: :active}} = Account.read(resources.account)
  end

  test "resume skips an evicted generation and preserves its replacement", %{
    name: name,
    config: config
  } do
    config = restart_with_one_task!(name, config)
    resources = parent_resources!(name, "replace", :claimed)
    terminal = terminal_task!(name, "replace", "generation-old")
    _ = manifest!(name, terminal, resources)
    {:ok, old} = Continuation.read(resources.cell)
    assert :ok = Continuation.retire(resources.cell, old.revision)

    {:ok, filler} =
      Continuation.open(ParentRuns.ledger(name), "filler", [], %{},
        parent: parent_packet!(name, %{"key" => "other"})
      )

    {:ok, pending} = Continuation.read(filler)
    {:ok, ready} = Continuation.ready(filler, pending.revision, %{})
    {:ok, claimed} = Continuation.claim(filler, ready.revision)
    assert :ok = Continuation.retire(filler, claimed.revision)

    {:ok, replacement} =
      Continuation.open(ParentRuns.ledger(name), resources.cell.key, [], %{},
        parent: parent_packet!(name, %{"key" => "new-task"})
      )

    assert replacement.generation != resources.cell.generation
    assert {:ok, %{state: :active, phase: :children}} = Continuation.read(replacement)

    assert {:ok, %{status: "cleaned"}} =
             Lifecycle.resume(config, name, "replace", terminal.revision)

    assert {:ok, %{state: :active, phase: :children}} = Continuation.read(replacement)
    assert {:ok, %{state: :retired}} = Account.read(resources.account)
  end

  test "retained parent resources block task id reuse after task and queue eviction", %{
    name: name,
    config: config
  } do
    restart_with_one_task!(name, config)

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "reuse",
               "profile" => "parent",
               "task" => "work"
             })

    _ = eventually(name, "reuse", "completed")

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "evict",
               "profile" => "echo",
               "task" => "work"
             })

    _ = eventually(name, "evict", "completed")

    assert {:error, :not_found} =
             OperationLog.request(Service.component(name, :ledger), {:recovery, "reuse"})

    assert {:error, :unknown_task} = Tasks.command(name, "get", %{"id" => "reuse"})

    assert {:error, :task_id_retained} =
             Tasks.command(name, "submit", %{
               "id" => "reuse",
               "profile" => "parent",
               "task" => "new work"
             })
  end

  test "account-only cleanup closes the host-owned budget", %{name: name, config: config} do
    {:ok, account} =
      Account.open(ParentRuns.budgets(name), "task:account-only",
        max_effects: 20,
        max_model_requests: 20
      )

    terminal = synthetic_terminal(name, "account-only", "generation-account")
    assert {:ok, %{resources: 1}} = Lifecycle.cleanup(config, name, terminal)
    assert {:ok, %{state: :retired}} = Account.read(account)
  end

  test "root rule loops and aggregate children share cleanup without a separate journal", %{
    name: name,
    config: config
  } do
    rule =
      Alto.Config.default(
        provider: nil,
        loop: Alto.rule_loop(steps: ["integrate"]),
        tools: [Integrate],
        continuation_store: ParentRuns.ledger(name),
        checkpoint_version: "lifecycle-v1",
        max_effects: 20,
        max_model_requests: 20
      )

    config = %{config | profiles: Map.put(config.profiles, "rule", rule)}
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "rule-no-journal",
               "profile" => "rule",
               "task" => "{}"
             })

    task = eventually(name, "rule-no-journal", "completed")

    {:ok, entry} =
      OperationLog.request(ParentRuns.budgets(name), {:recovery, "task:rule-no-journal"})

    account = %Alto.Persistence.Retained{
      kind: Account,
      ledger: ParentRuns.budgets(name),
      key: "task:rule-no-journal",
      generation: entry.recovery["generation"]
    }

    assert {:ok, %{state: :active}} = Account.read(account)

    assert {:ok, %{resources: 2}} =
             Tasks.command(name, "cleanup", %{
               "id" => "rule-no-journal",
               "revision" => task["revision"]
             })

    assert {:ok, %{state: :retired}} = Account.read(account)

    [key] =
      Enum.map(OperationLog.request(Lifecycle.ledger(name), {:entries, :all}), & &1.operation_key)

    {:ok, cleanup} = OperationLog.request(Lifecycle.ledger(name), {:recovery, key})
    assert Map.keys(cleanup.recovery["stores"]) |> Enum.sort() == ["binding", "budget", "parent"]

    resources = parent_resources!(name, "missing-journal", :claimed)
    terminal = synthetic_terminal(name, "missing-journal", "generation-missing")

    terminal =
      put_in(terminal, [:recovery, :payload, "profile"], "rule")

    assert {:ok, %{resources: 3}} = Lifecycle.cleanup(config, name, terminal)
    assert {:ok, %{state: :retired}} = Continuation.read(resources.cell)
    assert {:ok, %{state: :retired}} = Account.read(resources.account)
  end

  test "cleanup leaves an externally shared account active", %{name: name, config: config} do
    {:ok, external} =
      Account.open(ParentRuns.budgets(name), "shared-external",
        max_effects: 20,
        max_model_requests: 20
      )

    resources = parent_resources!(name, "external", :claimed, external)
    profile = config.profiles["parent"]
    shared = Alto.Config.default(Keyword.put(profile, :budget_account, external))
    config = %{config | profiles: Map.put(config.profiles, "parent", shared)}
    terminal = synthetic_terminal(name, "external", "generation-external")

    assert {:ok, %{resources: 2}} = Lifecycle.cleanup(config, name, terminal)
    assert {:ok, %{state: :retired}} = Continuation.read(resources.cell)
    assert {:ok, %{state: :active}} = Account.read(external)
  end

  test "pending children and unclaimed ready parent frames cannot be cleaned", %{
    name: name,
    config: config
  } do
    for phase <- [:children, :ready] do
      id = "incomplete-#{phase}"
      resources = parent_resources!(name, id, phase)
      terminal = synthetic_terminal(name, id, "generation-#{phase}")

      assert {:error, :unconsumed_parent_resources} = Lifecycle.cleanup(config, name, terminal)
      key = id <> ":" <> terminal.recovery[:generation_id]
      assert {:error, :not_found} = OperationLog.request(Lifecycle.ledger(name), {:recovery, key})
      assert {:ok, %{state: :active}} = Continuation.read(resources.cell)
      assert {:ok, %{state: :active}} = Account.read(resources.account)
    end
  end

  defp restart_with_one_task!(name, config) do
    config = %{
      config
      | scheduling: Keyword.put(config.scheduling, :max_tasks, 1),
        child_runs: Keyword.put(config.child_runs, :max_retained, 1)
    }

    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    config
  end

  defp parent_resources!(name, id, phase, existing_account \\ nil) do
    account =
      if existing_account do
        existing_account
      else
        {:ok, account} =
          Account.open(ParentRuns.budgets(name), "task:" <> id,
            max_effects: 20,
            max_model_requests: 20
          )

        account
      end

    packet = parent_packet!(name, Account.identity(account))
    run_id = "synthetic:" <> id
    :ok = ParentRuns.record_run(name, id, run_id)

    {:ok, cell} =
      Continuation.open(
        ParentRuns.ledger(name),
        "parent:" <> id,
        ["child"],
        %{"parent_run_id" => run_id},
        parent: packet
      )

    {:ok, _} = Continuation.skip(cell, "child", :done)

    if phase in [:ready, :claimed] do
      {:ok, pending} = Continuation.read(cell)
      {:ok, ready} = Continuation.ready(cell, pending.revision, packet)
      if phase == :claimed, do: {:ok, _} = Continuation.claim(cell, ready.revision)
    end

    %{account: account, cell: cell}
  end

  defp parent_packet!(name, account) do
    {:ok, store} = OperationLog.request(ParentRuns.ledger(name), :identity)

    {:ok, state} =
      Alto.Runner.Checkpoint.encode(%{
        budget: %{"account" => account},
        run: %{op_seq: 1},
        binding: %{store: store}
      })

    %{"kind" => "parent", "continuation_format" => 4, "state" => state}
  end

  defp synthetic_terminal(name, id, generation, revision \\ 7) do
    {:ok, binding} = OperationLog.request(ParentRuns.ledger(name), :identity)

    %{
      revision: revision,
      recovery: %{
        generation_id: generation,
        payload: %{"id" => id, "profile" => "parent", "parent_store" => binding}
      }
    }
  end

  defp terminal_task!(name, id, generation) do
    ledger = Service.component(name, :ledger)
    terminal = synthetic_terminal(name, id, generation)

    :ok =
      OperationLog.request(ledger, {:intent, id, "alto_resident_task", nil, terminal.recovery})

    :ok = OperationLog.request(ledger, {:attempt, id, "fake-attempt"})
    :ok = OperationLog.request(ledger, {:outcome, id, "fake-attempt", :completed, %{}})
    {:ok, recovered} = OperationLog.request(ledger, {:recovery, id})
    recovered
  end

  defp manifest!(name, terminal, resources) do
    id = terminal.recovery[:payload]["id"]
    generation = terminal.recovery[:generation_id]

    {:ok, binding, binding_snapshot} =
      Alto.Persistence.Retained.lookup(ParentRuns.bindings(name), id, ParentRuns)

    {:ok, cell} = Continuation.read(resources.cell)
    {:ok, account} = Account.read(resources.account)

    resource = fn role, identity, snapshot ->
      %{"role" => role, "identity" => identity, "revision" => snapshot.revision}
    end

    stores = %{
      "parent" => ParentRuns.ledger(name),
      "binding" => ParentRuns.bindings(name),
      "budget" => ParentRuns.budgets(name)
    }

    bindings =
      Map.new(stores, fn {role, server} ->
        {:ok, identity} = OperationLog.request(server, :identity)
        {role, identity}
      end)

    plan = %{
      "task" => id,
      "generation" => generation,
      "task_revision" => terminal.revision,
      "profile" => terminal.recovery[:payload]["profile"],
      "parent_store" => terminal.recovery[:payload]["parent_store"],
      "stores" => bindings,
      "resources" => [
        resource.("binding", Alto.Persistence.Retained.identity(binding), binding_snapshot),
        resource.("parent", Continuation.identity(resources.cell), cell),
        resource.("budget", Account.identity(resources.account), account)
      ]
    }

    key = id <> ":" <> generation

    :ok =
      OperationLog.request(
        Lifecycle.ledger(name),
        {:intent, key, "alto_resident_task_cleanup", nil, plan}
      )

    {key, plan}
  end

  defp eventually(name, id, status),
    do: Alto.Test.ResidentTask.await(name, id, status, 300, 20)
end
