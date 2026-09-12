defmodule Alto.Runner.ParentCheckpointTest do
  use ExUnit.Case, async: true

  alias Alto.{Effect, OperationLog, Usage}
  alias Alto.Runner.{Budget, Checkpoint}
  alias Alto.Runner.Budget.Account
  alias Alto.Subagents.Journal

  defmodule Loop do
    @behaviour Alto.Loop
    def init(task, _spec), do: Alto.Transition.continue(task)
    def handle_event(_event, state, _spec), do: Alto.Transition.continue(state)
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
    {:ok, journal} = Journal.open(ledger, "children:root:op-1", ["worker"])
    messages = [%{"role" => "user", "content" => "original task"}]

    run = %{
      spec: Alto.loop(Loop),
      tools: %{},
      model_tools: MapSet.new(),
      checkpoint_version: "parent-v1",
      continuation_store: ledger,
      agent_depth: 0,
      agent_identity: %{root_run_id: "root", path: []},
      tool_context: %{cwd: dir, agent_identity: %{root_run_id: "root", path: []}},
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
      compacted?: false,
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

    pending = %{kind: :children, journal: Journal.identity(journal), ids: ["worker"]}
    %{run: run, pending: pending, opts: opts, dir: dir}
  end

  test "round trip preserves parent state and tail without an approval request", context do
    %{run: run, pending: pending, opts: opts} = context
    tail = [Effect.request_model(%{context_message: "integrate"})]
    assert :ok = Budget.take(run.budget)
    assert {:ok, packet} = Checkpoint.capture_parent(run, pending, tail, {:stop, "tail done"})

    assert {:ok, same_packet} =
             Checkpoint.capture_parent(run, pending, tail, {:stop, "tail done"})

    assert same_packet["fingerprint"] == packet["fingerprint"]
    assert packet["kind"] == "parent"
    assert packet["stage"] == "children"
    refute Map.has_key?(packet, "request")
    packet = packet |> JSON.encode!() |> JSON.decode!()

    # Children can spend shared reservations after the pending parent is saved.
    assert :ok = Budget.take(run.budget)
    assert :ok = Budget.take_model(run.budget)
    assert {:ok, restored, frame} = Checkpoint.restore_parent(run, packet, opts)
    assert restored.loop_state == run.loop_state
    assert restored.messages_rev == run.messages_rev
    assert restored.persistence_errors == run.persistence_errors
    assert restored.usage == run.usage
    assert restored.op_seq == 1
    assert frame == %{pending: pending, remaining: tail, terminal: {:stop, "tail done"}}
    assert Budget.snapshot(restored.budget)["effects_used"] == 2
    assert Budget.snapshot(restored.budget)["model_requests_used"] == 1
  end

  test "restore and subsequent capture keep the original expiry", context do
    %{run: run, pending: pending, opts: opts} = context
    expiry = System.system_time(:millisecond) + 500
    run = Map.put(run, :parent_expires_at_ms, expiry)
    assert {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)
    assert packet["expires_at_ms"] == expiry
    assert {:ok, restored, _} = Checkpoint.restore_parent(run, packet, opts)
    assert Budget.remaining(restored.budget) <= 500

    assert {:ok, ready} =
             Checkpoint.capture_parent(restored, %{kind: :frame}, [], {:stop, "done"})

    assert ready["expires_at_ms"] <= expiry
    assert ready["stage"] == "frame"

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
    missing = Alto.Subagents.bounded(journal: :missing_checkpoint_journal)
    unavailable = %{run | spec: %{run.spec | subagents: missing}}

    assert {:error, {:durable_identity_unavailable, _}} =
             Checkpoint.capture_parent(unavailable, pending, [], :continue)

    {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)

    assert {:error, {:durable_identity_unavailable, _}} =
             Checkpoint.restore_parent(unavailable, packet, opts)

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000
    nested = Alto.Subagents.bounded(journal: dead)
    nested_options = %{run | spec: %{run.spec | driver_options: [nested_policy: nested]}}

    assert {:error, {:durable_identity_unavailable, _}} =
             Checkpoint.capture_parent(nested_options, pending, [], :continue)
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

  test "mismatched envelope and malformed pending state fail before restoration", context do
    %{run: run, pending: pending, opts: opts} = context
    {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)

    for changed <- [
          Map.put(packet, "stage", "frame"),
          Map.put(packet, "session_id", "other"),
          Map.put(packet, "expires_at_ms", packet["expires_at_ms"] + 1),
          put_in(packet, ["authority", "max_steps"], 100),
          put_in(packet, ["budget", "effects_used"], 0.5)
        ] do
      assert {:error, _} = Checkpoint.restore_parent(run, changed, opts)
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

    for intent <- [pending, %{kind: :frame}] do
      assert {:ok, packet} = Checkpoint.capture_parent(run, intent, [], :continue)

      assert :ok =
               Alto.Session.write_transcript(run.session, run.messages_rev, run.transcript_bytes,
                 session_dir: run.session_dir
               )

      assert {:error, :checkpoint_mismatch} = Checkpoint.restore_parent(run, packet, opts)
    end
  end

  defp replace_expiry(packet, expiry) do
    {:ok, saved} = Checkpoint.decode(packet["state"])
    {:ok, state} = Checkpoint.encode(put_in(saved, [:binding, :expires_at_ms], expiry))
    packet |> Map.put("expires_at_ms", expiry) |> Map.put("state", state)
  end
end
