defmodule Alto.SessionRecoveryTest do
  use ExUnit.Case, async: true
  alias Alto.Session
  alias Alto.Context.Transcript

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-recovery-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [session_dir: dir]
    {:ok, id} = Session.create("original task", %{run_id: "run-old"}, opts)
    messages = [%{"role" => "user", "content" => "original task"}]
    {:ok, _} = Session.persist_settled(id, messages, Transcript.bytes(messages), opts)

    {:ok, _} =
      Session.mark_dispatched(id, ["run-old:op-1"], Keyword.put(opts, :run_id, "run-old"))

    %{id: id, opts: opts}
  end

  test "a confirmed cancelled owner can resume with explicit uncertainty and retained evidence",
       %{id: id, opts: opts} do
    calls = [%{id: "spawn", name: "spawn_agents", arguments_json: "{}"}]
    event = Alto.Event.durable(:model_completed, %{tool_calls: calls})
    :ok = Session.append(id, Session.event_record("run-old", event), opts)

    :ok =
      Session.append(id, Session.completed_record(%{run_id: "run-old", status: :cancelled}), opts)

    assert {:error, {:session_unsettled_tool_dispatch, _}} = Session.resume_options(id, opts)

    assert {:error, :recovery_transcript_too_large} =
             Session.Recovery.cancelled(id, Keyword.put(opts, :max_transcript_bytes, 1))

    assert {:ok, snapshot} = Session.Recovery.cancelled(id, opts)
    assert snapshot["revision"] == 2
    assert snapshot["dispatch"] == nil
    assert hd(snapshot["messages"])["content"] == "original task"
    note = snapshot["messages"] |> List.last() |> Map.fetch!("content") |> JSON.decode!()
    assert note["outcome"] == "unknown"
    assert note["unknown_operation_ids"] == ["run-old:op-1"]
    assert hd(note["last_requested_tools"])["name"] == "spawn_agents"
    assert {:ok, _} = Session.resume_options(id, opts)
  end

  test "active, crashed, mismatched and child completions cannot bypass a fence", %{
    id: id,
    opts: opts
  } do
    assert {:error, :cancelled_run_recovery_unavailable} = Session.Recovery.cancelled(id, opts)

    for fields <- [
          %{run_id: "run-old", status: :error},
          %{run_id: "other-run", status: :cancelled},
          %{run_id: "run-old", status: :cancelled, session_owner: false, subagent: true}
        ] do
      :ok = Session.append(id, Session.completed_record(fields), opts)
      assert {:error, :cancelled_run_recovery_unavailable} = Session.Recovery.cancelled(id, opts)
      assert {:error, {:session_unsettled_tool_dispatch, _}} = Session.resume_options(id, opts)
    end
  end
end
