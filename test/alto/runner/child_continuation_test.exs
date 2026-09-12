defmodule Alto.Runner.ChildContinuationTest do
  use ExUnit.Case, async: false
  alias Alto.{Effect, Event, OperationLog, Transition}
  alias Alto.Runner.Budget.Account
  alias Alto.Subagents.{Continuation, Journal}

  defmodule Parent do
    @behaviour Alto.Loop
    def init(%{agents: agents}, spec) do
      File.write!(Path.join(spec.driver_options[:dir], "planner"), "1", [:append])
      Transition.continue(%{}, [Effect.spawn_agents(%{agents: agents})])
    end

    def handle_event(%Event{type: :subagents_completed, data: data}, state, _spec) do
      Transition.continue(Map.put(state, :results, data.results), [
        Effect.invoke_tool(%{id: "integrate", name: "integrate", arguments: %{}})
      ])
    end

    def handle_event(%Event{type: :tool_completed}, state, _spec),
      do: Transition.stop(state, state.results)

    def handle_event(_, state, _), do: Transition.continue(state)
    def dump_checkpoint(state, _), do: {:ok, state}
    def load_checkpoint(state, _), do: {:ok, state}

    def resolve_child_provider("worker", _spec),
      do: {:ok, :persistent_term.get({__MODULE__, :provider})}

    def resolve_child_provider(_, _), do: {:error, :unknown_profile}
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(:persistent_term.get({__MODULE__, :observer}), {:provider_key, opts[:api_key]})

      if List.last(request.messages)["role"] == "user" do
        {:ok,
         %{
           message: "working",
           tool_calls: [%{id: "guard", name: "guarded", arguments_json: ~s({"id":"one"})}]
         }}
      else
        {:ok, %{message: "done", tool_calls: []}}
      end
    end
  end

  defmodule ChildLoop do
    @behaviour Alto.Loop
    def init(task, spec), do: Alto.Loops.Rule.init(task, spec)
    def handle_event(event, state, spec), do: Alto.Loops.Rule.handle_event(event, state, spec)
    def dump_checkpoint(state, spec), do: Alto.Loops.Rule.dump_checkpoint(state, spec)

    def load_checkpoint(state, spec) do
      if observer = :persistent_term.get({__MODULE__, :observer}, nil) do
        send(observer, {:restoring_child, self()})

        receive do
          :release -> :ok
        end
      end

      Alto.Loops.Rule.load_checkpoint(state, spec)
    end
  end

  defmodule WorkspaceBackend do
    @behaviour Alto.Workspaces.Backend
    def snapshot(source, _opts) do
      File.write!(Path.join(source, "snapshots"), "1", [:append])
      {:ok, %{"source" => source}}
    end

    def checkout(snapshot, path, _opts) do
      File.write!(Path.join(snapshot["source"], "checkouts"), "1", [:append])
      File.mkdir_p!(path)
      File.cp!(Path.join(snapshot["source"], "input"), Path.join(path, "input"))
      :ok
    end

    def diff(snapshot, _path, _opts) do
      File.write!(Path.join(snapshot["source"], "diffs"), "1", [:append])
      {:ok, "patch"}
    end

    def prepare_apply(_, _, _, _), do: {:error, :unsupported}
    def verify_apply(_, _, _, _), do: {:error, :unsupported}
    def apply(_, _, _, _), do: {:error, :unsupported}
  end

  defmodule Integrate do
    @behaviour Alto.Tool
    def name, do: :integrate
    def schema, do: %{description: "Integrate", parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :exclusive
    def approval, do: :never

    def run(_, context) do
      File.write!(Path.join(context.cwd, "integration"), "1", [:append])
      {:ok, "integrated"}
    end
  end

  defmodule First do
    @behaviour Alto.Tool
    def name, do: :first
    def schema, do: %{description: "First", parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :exclusive
    def approval, do: :never

    def run(%{"id" => id}, context) do
      File.write!(Path.join(context.cwd, "first-" <> id), "1", [:append])
      {:ok, "first"}
    end
  end

  defmodule Guarded do
    @behaviour Alto.Tool
    def name, do: :guarded
    def schema, do: %{description: "Guarded", parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :exclusive
    def approval, do: :required

    def prepare(%{"id" => id}, context) do
      File.write!(Path.join(context.cwd, "prepared-" <> id), "1", [:append])
      {:ok, %{id: id, value: File.read!(Path.join(context.cwd, "input"))}, %{id: id}}
    end

    def run_prepared(%{id: id, value: value}, context) do
      if observer = :persistent_term.get({__MODULE__, :observer}, nil) do
        send(observer, {:executing, self()})

        receive do
          :release -> :ok
        end
      end

      File.write!(Path.join(context.cwd, "effect-" <> id), value, [:append])
      {:ok, value}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-child-resume-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "input"), "original")
    on_exit(fn -> File.rm_rf!(dir) end)

    ledger_opts = [
      id: "children",
      name: nil,
      dir: dir,
      max_recovery_bytes: 3_000_000,
      max_record_bytes: 4_000_000
    ]

    ledger = start_supervised!({OperationLog, ledger_opts})
    {:ok, account} = Account.open(ledger, "budget", max_effects: 50, max_model_requests: 20)
    %{dir: dir, ledger: ledger, ledger_opts: ledger_opts, account: account}
  end

  defp opts(context, runner, sessions \\ :separate) do
    [
      runner: runner,
      cwd: context.dir,
      loop:
        Alto.loop(Parent,
          dir: context.dir,
          subagents:
            Alto.Subagents.bounded(
              max_depth: 1,
              max_children: 4,
              max_concurrency: 2,
              sessions: sessions,
              journal: context.ledger
            )
        ),
      tools: [First, Guarded, Integrate],
      approval: Alto.Approvals.Checkpoint,
      checkpoint_version: "child-v1",
      continuation_store: context.ledger,
      budget_account: context.account,
      max_effects: 50,
      max_model_requests: 20,
      run_timeout: 30_000,
      session: :new,
      session_dir: context.dir
    ]
  end

  defp agent(id, steps \\ ["first", "guarded"]),
    do: %{id: id, task: %{"id" => id}, loop: Alto.rule_loop(steps: steps)}

  defp journal(context, result) do
    identity = result.checkpoint["continuation"]
    assert {:ok, cell} = Continuation.restore(context.ledger, identity)
    assert {:ok, snapshot} = Continuation.read(cell)
    assert {:ok, batch} = Journal.restore(context.ledger, snapshot.metadata["journal"])
    {identity, batch}
  end

  defp decide(batch, id, decision) do
    {:ok, entries} = Journal.suspended(batch)
    entry = Enum.find(entries, &(&1.id == id))
    {:ok, snapshot} = Journal.read(batch)
    assert {:ok, _} = Journal.decide(batch, snapshot.revision, entry.identity, decision)
    entry
  end

  for runner <- [Alto.Runner.Serial, Alto.Runner.Stepped], sessions <- [:separate, :shared] do
    test "#{runner} resumes only decided sibling with #{sessions} transcript ownership",
         context do
      options = opts(context, unquote(runner), unquote(sessions))

      assert {:error, {:children_pending, {:child_pending, "one", "suspended"}}, parked} =
               Alto.run(%{agents: [agent("one"), agent("two")]}, options)

      {identity, batch} = journal(context, parked)
      assert {:ok, entries} = Journal.suspended(batch)
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.checkpoint["request"]["tool"] == "guarded"))
      assert File.read!(Path.join(context.dir, "first-one")) == "1"
      refute File.exists?(Path.join(context.dir, "effect-one"))
      refute File.exists?(Path.join(context.dir, "integration"))
      File.write!(Path.join(context.dir, "input"), "changed")
      first = decide(batch, "one", :approve)
      options = Keyword.put(options, :continuation, identity)

      assert {:error, {:children_pending, {:child_pending, "two", "suspended"}}, _} =
               Alto.run(:ignored, options)

      assert File.read!(Path.join(context.dir, "effect-one")) == "original"
      assert File.read!(Path.join(context.dir, "prepared-one")) == "1"
      {:ok, snapshot} = Journal.read(batch)

      assert {:error, :stale_child_decision} =
               Journal.decide(batch, snapshot.revision, first.identity, :approve)

      decide(batch, "two", :deny)
      assert {:ok, result} = Alto.run(:ignored, options)
      assert Enum.map(result.output, & &1.status) == [:ok, :error]
      assert File.read!(Path.join(context.dir, "planner")) == "1"
      assert File.read!(Path.join(context.dir, "integration")) == "1"
      refute File.exists?(Path.join(context.dir, "effect-two"))
      assert {:ok, joined} = Journal.join(batch)
      assert length(joined.results) == 2

      for {_, child} <- joined.results do
        if unquote(sessions) == :separate do
          assert child.session_id != result.session_id
          assert {:ok, _} = Alto.Session.transcript(child.session_id, session_dir: context.dir)
        else
          assert child.session_id == result.session_id
        end
      end

      assert {:ok, transcript} =
               Alto.Session.transcript(result.session_id, session_dir: context.dir)

      assert transcript.messages == result.messages
    end
  end

  test "a persisted decision survives store restart and a second approval has a new fence",
       context do
    options = opts(context, Alto.Runner.Serial)

    assert {:error, {:children_pending, _}, parked} =
             Alto.run(%{agents: [agent("one", ["first", "guarded", "guarded"])]}, options)

    {identity, batch} = journal(context, parked)
    first = decide(batch, "one", :approve)
    stop_supervised!(OperationLog)
    ledger = start_supervised!({OperationLog, context.ledger_opts})
    {:ok, account} = Account.open(ledger, "budget", max_effects: 50, max_model_requests: 20)
    context = %{context | ledger: ledger, account: account}
    options = context |> opts(Alto.Runner.Stepped) |> Keyword.put(:continuation, identity)
    assert {:error, {:children_pending, _}, parked} = Alto.run(:ignored, options)
    {_, batch} = journal(context, parked)
    {:ok, [second]} = Journal.suspended(batch)
    refute first.identity == second.identity
    {:ok, snapshot} = Journal.read(batch)

    assert {:error, :stale_child_decision} =
             Journal.decide(batch, snapshot.revision, first.identity, :deny)

    decide(batch, "one", :approve)
    assert {:ok, _} = Alto.run(:ignored, options)
    assert File.read!(Path.join(context.dir, "effect-one")) == "originaloriginal"
    assert File.read!(Path.join(context.dir, "first-one")) == "1"
    assert File.read!(Path.join(context.dir, "prepared-one")) == "11"
    assert {:ok, snapshot} = Account.read(account)
    assert snapshot.packet["effects_used"] == 5
  end

  test "a losing child resume cannot retain over the winner after both validate", context do
    options = opts(context, Alto.Runner.Serial)
    agent = %{agent("one") | loop: Alto.loop(ChildLoop, steps: ["first", "guarded"])}
    assert {:error, {:children_pending, _}, parked} = Alto.run(%{agents: [agent]}, options)
    {identity, batch} = journal(context, parked)
    decide(batch, "one", :approve)
    :persistent_term.put({Guarded, :observer}, self())
    :persistent_term.put({ChildLoop, :observer}, self())

    on_exit(fn ->
      :persistent_term.erase({Guarded, :observer})
      :persistent_term.erase({ChildLoop, :observer})
    end)

    options = Keyword.put(options, :continuation, identity)
    first = Task.async(fn -> Alto.run(:ignored, options) end)
    assert_receive {:restoring_child, first_restore}, 2_000
    second = Task.async(fn -> Alto.run(:ignored, options) end)
    assert_receive {:restoring_child, second_restore}, 2_000
    send(first_restore, :release)
    assert_receive {:executing, worker}, 2_000
    send(second_restore, :release)

    assert {:error, {:children_pending, {:child_pending, "one", "resuming"}}, _} =
             Task.await(second, 5_000)

    assert {:error, {:child_pending, "one", "resuming"}} = Journal.join(batch)
    refute_receive {:executing, _}, 50
    send(worker, :release)
    assert {:ok, result} = Task.await(first, 5_000)
    assert File.read!(Path.join(context.dir, "effect-one")) == "original"
    assert File.read!(Path.join(context.dir, "integration")) == "1"
    assert {:ok, %{results: [{"one", child}]}} = Journal.join(batch)
    assert child.status == :ok

    assert {:ok, child_transcript} =
             Alto.Session.transcript(child.session_id, session_dir: context.dir)

    assert child_transcript.revision == 1

    assert {:ok, transcript} =
             Alto.Session.transcript(result.session_id, session_dir: context.dir)

    assert transcript.messages == result.messages
  end

  test "approved child resumes its worked workspace without preparing it again", context do
    source = Path.join(context.dir, "source")
    File.mkdir_p!(source)
    File.cp!(Path.join(context.dir, "input"), Path.join(source, "input"))
    options = Keyword.put(opts(context, Alto.Runner.Stepped), :cwd, source)

    manager =
      Alto.Workspaces.new(
        root: Path.join(context.dir, "workspaces"),
        ledger: context.ledger,
        backend: WorkspaceBackend
      )

    loop = options[:loop]

    options =
      Keyword.put(options, :loop, %{loop | subagents: %{loop.subagents | workspaces: manager}})

    assert {:error, {:children_pending, _}, parked} = Alto.run(%{agents: [agent("one")]}, options)
    {identity, batch} = journal(context, parked)
    {:ok, [%{workspace: worked}]} = Journal.suspended(batch)
    assert worked.status == "worked"
    assert File.read!(Path.join(source, "snapshots")) == "1"
    assert File.read!(Path.join(source, "checkouts")) == "1"
    refute File.exists?(Path.join(source, "diffs"))

    assert {:error, :stale_workspace} =
             Alto.Workspaces.resume(manager, worked.id, worked.revision - 1, fn _ ->
               flunk("stale workspace was entered")
             end)

    decide(batch, "one", :approve)
    assert {:ok, result} = Alto.run(:ignored, Keyword.put(options, :continuation, identity))
    assert [child] = result.output
    assert child.workspace.status == "frozen"
    assert child.workspace.id == worked.id

    assert {:error, :stale_workspace} =
             Alto.Workspaces.resume(manager, worked.id, worked.revision, fn _ ->
               flunk("old workspace was entered")
             end)

    assert {:error, :workspace_not_ready} =
             Alto.Workspaces.resume(manager, worked.id, child.workspace.revision, fn _ ->
               flunk("frozen workspace was entered")
             end)

    assert File.read!(Path.join(worked.workspace["cwd"], "effect-one")) == "original"
    assert File.read!(Path.join(worked.workspace["cwd"], "prepared-one")) == "1"
    assert File.read!(Path.join(source, "snapshots")) == "1"
    assert File.read!(Path.join(source, "checkouts")) == "1"
    assert File.read!(Path.join(source, "diffs")) == "1"
  end

  test "a claimed child with uncertain dispatch remains parked and cannot be approved again",
       context do
    options = opts(context, Alto.Runner.Serial)
    assert {:error, {:children_pending, _}, parked} = Alto.run(%{agents: [agent("one")]}, options)
    {identity, batch} = journal(context, parked)
    entry = decide(batch, "one", :approve)
    assert {:ok, _} = Journal.claim_child(batch, entry.identity, :approve)
    options = Keyword.put(options, :continuation, identity)

    assert {:error, {:children_pending, {:child_pending, "one", "resuming"}}, _} =
             Alto.run(:ignored, options)

    {:ok, snapshot} = Journal.read(batch)

    assert {:error, :stale_child_decision} =
             Journal.decide(batch, snapshot.revision, entry.identity, :approve)

    refute File.exists?(Path.join(context.dir, "effect-one"))
    refute File.exists?(Path.join(context.dir, "integration"))
  end

  test "host downtime consumes the original absolute expiry", context do
    options = Keyword.put(opts(context, Alto.Runner.Stepped), :run_timeout, 750)
    assert {:error, {:children_pending, _}, parked} = Alto.run(%{agents: [agent("one")]}, options)
    {identity, batch} = journal(context, parked)
    decide(batch, "one", :approve)
    Process.sleep(800)
    options = options |> Keyword.put(:continuation, identity) |> Keyword.put(:run_timeout, 30_000)
    assert {:error, :run_timeout, _} = Alto.run(:ignored, options)
    assert {:ok, [%{state: :decided}]} = Journal.suspended(%{batch | deadline: :infinity})
    refute File.exists?(Path.join(context.dir, "effect-one"))
  end

  test "named child providers are re-resolved without retaining provider credentials", context do
    first_provider = {Provider, api_key: "first-secret"}
    :persistent_term.put({Parent, :provider}, first_provider)
    :persistent_term.put({Provider, :observer}, self())

    on_exit(fn ->
      :persistent_term.erase({Parent, :provider})
      :persistent_term.erase({Provider, :observer})
    end)

    options = opts(context, Alto.Runner.Serial)
    child = %{id: "one", task: "work", provider: first_provider, profile_key: "worker"}
    assert {:error, {:children_pending, _}, parked} = Alto.run(%{agents: [child]}, options)
    assert_receive {:provider_key, "first-secret"}, 2_000
    {identity, batch} = journal(context, parked)
    {:ok, [entry]} = Journal.suspended(batch)
    {:ok, binding} = Alto.Runner.Checkpoint.child_binding(entry.checkpoint)
    assert binding.profile.provider == nil
    assert binding.profile.profile_key == "worker"
    refute inspect(binding) =~ "first-secret"
    refute inspect(entry.checkpoint) =~ "first-secret"
    :persistent_term.put({Parent, :provider}, {Provider, api_key: "second-secret"})
    decide(batch, "one", :approve)
    assert {:ok, result} = Alto.run(:ignored, Keyword.put(options, :continuation, identity))
    assert_receive {:provider_key, "second-secret"}, 2_000
    assert hd(result.output).output == "done"
    assert File.read!(Path.join(context.dir, "prepared-one")) == "1"
    assert File.read!(Path.join(context.dir, "effect-one")) == "original"
  end

  test "cancelling a recovered parent promptly cancels its blocked resumed child", context do
    options = opts(context, Alto.Runner.Stepped)
    assert {:error, {:children_pending, _}, parked} = Alto.run(%{agents: [agent("one")]}, options)
    {identity, batch} = journal(context, parked)
    decide(batch, "one", :approve)
    :persistent_term.put({Guarded, :observer}, self())
    on_exit(fn -> :persistent_term.erase({Guarded, :observer}) end)
    assert {:ok, parent} = Alto.start(:ignored, Keyword.put(options, :continuation, identity))
    assert_receive {:executing, _worker}, 2_000
    started = System.monotonic_time(:millisecond)
    assert :ok = Alto.cancel(parent, :user_stop)
    assert {:error, {:cancelled, :user_stop}, _} = Alto.await(parent, 3_000)
    assert System.monotonic_time(:millisecond) - started < 2_000
    assert {:ok, %{results: [{"one", child}]}} = Journal.join(batch)
    assert child.status == :cancelled
    refute File.exists?(Path.join(context.dir, "effect-one"))
    refute File.exists?(Path.join(context.dir, "integration"))
  end
end
