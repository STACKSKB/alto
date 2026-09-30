defmodule Alto.Runner.ParentCheckpointTest do
  use ExUnit.Case, async: true

  alias Alto.{OperationLog, Usage}
  alias Alto.Runner.{Budget, Checkpoint}
  alias Alto.Runner.Budget.Account

  defmodule Loop do
    @behaviour Alto.Loop
    def init(task, _spec), do: {:continue, task, []}
    def handle_event(_event, state, _spec), do: {:continue, state, []}
    def dump_checkpoint(state, _spec), do: {:ok, state}
    def load_checkpoint(state, _spec), do: {:ok, state}
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-parent-checkpoint-#{System.unique_integer([:positive])}")

    ledger = start_supervised!({OperationLog, name: nil, id: "parents", dir: dir})
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, account} = Account.open(ledger, "tree", max_effects: 50, max_model_requests: 20)
    opts = [budget_account: account, max_effects: 50, max_model_requests: 20, run_timeout: 10_000]
    {:ok, budget} = Budget.new(opts)
    messages = [%{"role" => "user", "content" => "original task"}]

    run = %{
      spec: Alto.loop(Loop),
      tools: %{},
      model_tools: MapSet.new(),
      checkpoint_version: "parent-v1",
      continuation_store: ledger,
      agent_depth: 0,
      agent_identity: %{root_run_id: "root", path: []},
      cwd: dir,
      loop_state: %{phase: :children},
      messages_rev: messages,
      transcript_bytes: Alto.Context.Transcript.bytes(messages),
      transcript_revision: :any,
      model_requests: 1,
      usage: Usage.normalize(%{input_tokens: 3, output_tokens: 2}),
      verdict: :empty,
      op_seq: 1,
      pending_provider_calls: %{},
      request_model_tools: nil,
      compaction_count: 0,
      resolved_operations: [],
      persistence_errors: [{:earlier_write, :unavailable}],
      session: nil,
      session_dir: dir,
      budget: budget,
      max_steps: 10,
      max_agent_depth: 2,
      max_tool_result_bytes: 64_000,
      max_transcript_bytes: 200_000,
      max_approval_details_bytes: 32_000,
      max_events: 100,
      provider_timeout: 1_000,
      tool_timeout: 1_000,
      approval_timeout: 1_000
    }

    pending = %{kind: :children, ids: ["worker"]}
    %{run: run, pending: pending, opts: opts, dir: dir}
  end

  test "round trip preserves parent state and tail without an approval request", context do
    %{run: run, pending: pending, opts: opts} = context
    run = %{run | compaction_count: 2, usage: %{run.usage | context_window: 200_000}}
    tail = [{:request_model, %{context_message: "integrate"}}]
    assert :ok = Budget.take(run.budget)
    assert {:ok, packet} = Checkpoint.capture_parent(run, pending, tail, {:stop, "tail done"})

    assert {:ok, same_packet} =
             Checkpoint.capture_parent(run, pending, tail, {:stop, "tail done"})

    assert {:ok, same} = Checkpoint.decode(same_packet["state"])
    assert {:ok, saved} = Checkpoint.decode(packet["state"])
    assert same.fingerprint == saved.fingerprint
    assert packet["kind"] == "parent"
    assert packet["request"] == nil
    packet = packet |> JSON.encode!() |> JSON.decode!()

    # Children can spend shared reservations after the pending parent is saved.
    assert :ok = Budget.take(run.budget)
    assert :ok = Budget.take_model(run.budget)
    assert {:ok, restored, frame} = Checkpoint.restore_parent(run, packet, opts)
    assert restored.loop_state == run.loop_state
    assert restored.messages_rev == run.messages_rev
    assert restored.persistence_errors == run.persistence_errors
    assert restored.compaction_count == 2
    assert restored.usage == run.usage
    assert restored.op_seq == 1
    assert frame == %{pending: pending, remaining: tail, terminal: {:stop, "tail done"}}
    assert Budget.snapshot(restored.budget)["effects_used"] == 2
    assert Budget.snapshot(restored.budget)["model_requests_used"] == 1
  end

  test "wire expansion does not reduce the encoded-state limit", context do
    %{run: run, pending: pending, opts: opts} = context
    run = %{run | loop_state: String.duplicate("x", 800_000)}
    assert {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)
    assert byte_size(packet["state"]) > 1_000_000
    assert {:ok, restored, _} = Checkpoint.restore_parent(run, packet, opts)
    assert restored.loop_state == run.loop_state

    assert {:error, :checkpoint_not_portable_or_too_large} =
             Checkpoint.capture_parent(
               %{run | loop_state: String.duplicate("x", 1_000_000)},
               pending,
               [],
               :continue
             )
  end

  test "restore and subsequent capture keep the original expiry", context do
    %{run: run, pending: pending, opts: opts} = context
    expiry = System.system_time(:millisecond) + 500
    run = Map.put(run, :parent_expires_at_ms, expiry)
    assert {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)
    assert {:ok, saved} = Checkpoint.decode(packet["state"])
    assert saved.binding.expires_at_ms == expiry
    assert {:ok, restored, _} = Checkpoint.restore_parent(run, packet, opts)
    assert Budget.remaining(restored.budget) <= 500

    assert {:ok, ready} =
             Checkpoint.capture_parent(restored, %{kind: :frame}, [], {:stop, "done"})

    assert {:ok, saved_ready} = Checkpoint.decode(ready["state"])
    assert saved_ready.binding.expires_at_ms <= expiry

    assert {:ok, _, %{pending: %{kind: :frame}}} =
             Checkpoint.restore_parent(restored, ready, opts)

    expired = replace_expiry(packet, System.system_time(:millisecond) - 1)
    assert {:error, :run_timeout} = Checkpoint.restore_parent(run, expired, opts)

    assert {:error, :run_timeout} =
             Checkpoint.capture_parent(
               Map.put(run, :parent_expires_at_ms, 0),
               pending,
               [],
               :continue
             )
  end

  test "durable account, root ownership and store binding are mandatory", context do
    %{run: run, pending: pending, opts: opts, dir: dir} = context
    {:ok, volatile} = Budget.new([])

    assert {:error, :parent_checkpoint_requires_budget_account} =
             Checkpoint.capture_parent(%{run | budget: volatile}, pending, [], :continue)

    assert {:error, :checkpoint_not_supported} =
             Checkpoint.capture_parent(%{run | agent_depth: 1}, pending, [], :continue)

    {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)

    assert {:error, :checkpoint_not_supported} =
             Checkpoint.restore_parent(%{run | agent_depth: 1}, packet, opts)

    assert {:error, :budget_account_mismatch} =
             Checkpoint.restore_parent(run, packet, Keyword.delete(opts, :budget_account))

    other =
      start_supervised!(
        Supervisor.child_spec(
          {OperationLog, name: nil, id: "foreign", dir: dir},
          id: :foreign
        )
      )

    assert {:error, :checkpoint_mismatch} =
             Checkpoint.restore_parent(%{run | continuation_store: other}, packet, opts)
  end

  test "unavailable durable policy resources fail capture and restore", context do
    %{run: run, pending: pending, opts: opts} = context
    unavailable = %{run | continuation_store: :missing_checkpoint_store}

    assert {:error, :parent_checkpoint_store_unavailable} =
             Checkpoint.capture_parent(unavailable, pending, [], :continue)

    {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)

    assert {:error, :parent_checkpoint_store_unavailable} =
             Checkpoint.restore_parent(unavailable, packet, opts)

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

    manager = Alto.Workspaces.new(root: Path.join(context.dir, "workers"), ledger: dead)
    nested = Alto.Subagents.bounded(max_depth: 2, max_children: 2, workspaces: manager)
    nested_options = %{run | spec: %{run.spec | driver_options: [nested_policy: nested]}}

    assert {:error, {:durable_identity_unavailable, _}} =
             Checkpoint.capture_parent(nested_options, pending, [], :continue)
  end

  test "resolved policy and nested factory resources bind durable identities", context do
    %{run: run, pending: pending, opts: opts} = context

    manager =
      Alto.Workspaces.new(root: Path.join(context.dir, "workers"), ledger: run.continuation_store)

    policy = Alto.Subagents.bounded(max_depth: 2, max_children: 2, workspaces: manager)
    factory = fn -> policy end
    configured = %{run | spec: %{run.spec | subagents: factory}}
    configured = Map.put(configured, :child_limits, policy)
    assert {:ok, packet} = Checkpoint.capture_parent(configured, pending, [], :continue)
    assert {:ok, _, _} = Checkpoint.restore_parent(configured, packet, opts)

    changed = Map.put(configured, :child_limits, %{policy | max_children: 3})
    assert {:error, :checkpoint_mismatch} = Checkpoint.restore_parent(changed, packet, opts)
  end

  test "restored authority is the intersection of saved and current ceilings", context do
    %{run: run, pending: pending, opts: opts} = context
    {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)

    changed = %{
      run
      | max_steps: 100,
        max_agent_depth: 1,
        max_tool_result_bytes: 32_000,
        max_approval_details_bytes: 64_000,
        tool_timeout: 500
    }

    assert {:ok, restored, _} = Checkpoint.restore_parent(changed, packet, opts)
    assert restored.max_steps == run.max_steps
    assert restored.max_agent_depth == 1
    assert restored.max_tool_result_bytes == 32_000
    assert restored.max_approval_details_bytes == run.max_approval_details_bytes
    assert restored.tool_timeout == 500

    assert {:error, :checkpoint_mismatch} =
             Checkpoint.restore_parent(%{run | max_transcript_bytes: 1}, packet, opts)
  end

  test "unlimited step policy survives checkpoints and respects finite authority", %{
    run: run,
    pending: pending,
    opts: opts
  } do
    unlimited = %{run | max_steps: :infinity}
    assert {:ok, packet} = Checkpoint.capture_parent(unlimited, pending, [], :continue)
    assert {:ok, restored, _} = Checkpoint.restore_parent(unlimited, packet, opts)
    assert restored.max_steps == :infinity
    assert {:ok, narrowed, _} = Checkpoint.restore_parent(run, packet, opts)
    assert narrowed.max_steps == run.max_steps

    assert {:ok, finite} = Checkpoint.capture_parent(run, pending, [], :continue)
    assert {:ok, restored, _} = Checkpoint.restore_parent(unlimited, finite, opts)
    assert restored.max_steps == run.max_steps
  end

  test "mismatched envelope and malformed pending state fail before restoration", context do
    %{run: run, pending: pending, opts: opts} = context
    {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)

    assert {:error, _} =
             Checkpoint.restore_parent(run, Map.put(packet, "session_id", "other"), opts)

    {:ok, saved} = Checkpoint.decode(packet["state"])

    for changed <- [
          Map.delete(saved, :loop),
          Map.put(saved, :unexpected, true),
          update_in(saved.run, &Map.delete(&1, :agent_identity)),
          put_in(saved, [:binding, :unexpected], true),
          put_in(saved, [:frame, :pending, :kind], :invalid),
          put_in(saved, [:budget, "effects_used"], 0.5),
          Map.put(saved, :budget, 7),
          put_in(saved, [:run, :messages_rev], [%{"content" => {:not, :json}}]),
          put_in(saved, [:binding, :store], %{}),
          put_in(saved, [:binding, :authority, :max_steps], -1),
          put_in(saved, [:run, :usage], %{run.usage | input_tokens: -1}),
          put_in(saved, [:run, :usage], %{run.usage | context_window: "invalid"}),
          put_in(saved, [:run, :usage], %{run.usage | input_tokens: nil}),
          put_in(saved, [:run, :agent_identity], %{root_run_id: "root", path: ["child"]})
        ] do
      {:ok, encoded} = Checkpoint.encode(changed)
      assert {:error, _} = Checkpoint.restore_parent(run, %{packet | "state" => encoded}, opts)
    end

    assert {:error, _} =
             Checkpoint.capture_parent(run, %{pending | ids: ["worker", "worker"]}, [], :continue)

    assert {:error, _} = Checkpoint.capture_parent(run, pending, [:not_an_effect], :continue)

    assert {:error, _} =
             Checkpoint.capture_parent(%{run | loop_state: self()}, pending, [], :continue)
  end

  test "a changed durable transcript rejects both pending and ready packets", context do
    %{run: run, pending: pending, opts: opts} = context
    {:ok, session} = Alto.Session.create("task", %{}, session_dir: run.session_dir)
    run = %{run | session: session}

    for {intent, index} <- Enum.with_index([pending, %{kind: :frame}]) do
      assert {:ok, packet} = Checkpoint.capture_parent(run, intent, [], :continue)

      messages = run.messages_rev ++ [%{"role" => "user", "content" => "changed #{index}"}]

      assert {:ok, _snapshot} =
               Alto.Session.persist_settled(
                 run.session,
                 messages,
                 Alto.Context.Transcript.bytes(messages),
                 session_dir: run.session_dir,
                 allow_pending: true
               )

      assert {:error, :checkpoint_mismatch} = Checkpoint.restore_parent(run, packet, opts)
    end
  end

  test "checkpoint identity binds a finite conversation retention policy", %{
    run: run,
    pending: pending,
    opts: opts
  } do
    finite = Map.put(run, :conversation_retained_turns, 3)
    {:ok, packet} = Checkpoint.capture_parent(finite, pending, [], :continue)
    assert {:ok, _, _} = Checkpoint.restore_parent(finite, packet, opts)

    assert {:error, :checkpoint_mismatch} =
             Checkpoint.restore_parent(
               Map.put(finite, :conversation_retained_turns, 4),
               packet,
               opts
             )

    assert {:error, :checkpoint_mismatch} = Checkpoint.restore_parent(run, packet, opts)
  end

  defp replace_expiry(packet, expiry) do
    {:ok, saved} = Checkpoint.decode(packet["state"])
    {:ok, state} = Checkpoint.encode(put_in(saved, [:binding, :expires_at_ms], expiry))
    Map.put(packet, "state", state)
  end

  test "a large durable transcript is referenced and restores below the packet limit", %{
    run: run,
    pending: pending,
    opts: opts
  } do
    messages = [%{"role" => "user", "content" => String.duplicate("context", 300_000)}]
    {:ok, session} = Alto.Session.create("large context", %{}, session_dir: run.session_dir)
    bytes = Alto.Context.Transcript.bytes(messages)

    {:ok, _} =
      Alto.Session.persist_settled(session, messages, bytes,
        session_dir: run.session_dir,
        conversation_retained_turns: 1
      )

    run = %{
      run
      | session: session,
        messages_rev: messages,
        transcript_bytes: bytes,
        max_transcript_bytes: 3_000_000
    }

    assert {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)
    assert byte_size(packet["state"]) < 20_000
    {:ok, saved} = Checkpoint.decode(packet["state"])
    assert saved.run.messages_rev["$conversation"] == 1
    assert {:ok, restored, _} = Checkpoint.restore_parent(run, packet, opts)
    assert restored.messages_rev == messages

    {:ok, forged} = Checkpoint.encode(put_in(saved, [:run, :messages_rev, "message_count"], 2))

    assert {:error, :checkpoint_mismatch} =
             Checkpoint.restore_parent(run, %{packet | "state" => forged}, opts)

    changed = [%{"role" => "user", "content" => "next turn"}]

    {:ok, _} =
      Alto.Session.persist_settled(session, changed, Alto.Context.Transcript.bytes(changed),
        session_dir: run.session_dir,
        conversation_retained_turns: 1
      )

    assert {:error, :checkpoint_mismatch} = Checkpoint.restore_parent(run, packet, opts)
  end

  test "legacy inline transcripts still restore with a saved session", %{
    run: run,
    pending: pending,
    opts: opts
  } do
    {:ok, session} = Alto.Session.create("legacy", %{}, session_dir: run.session_dir)

    {:ok, _} =
      Alto.Session.persist_settled(session, run.messages_rev, run.transcript_bytes,
        session_dir: run.session_dir
      )

    run = %{run | session: session}
    {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)
    {:ok, saved} = Checkpoint.decode(packet["state"])
    {:ok, state} = Checkpoint.encode(put_in(saved, [:run, :messages_rev], run.messages_rev))
    assert {:ok, restored, _} = Checkpoint.restore_parent(run, %{packet | "state" => state}, opts)
    assert restored.messages_rev == run.messages_rev
  end
end
