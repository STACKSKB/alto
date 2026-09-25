defmodule Alto.Runner.Execution.SessionTest do
  use ExUnit.Case, async: true

  alias Alto.Runner.Execution.Session, as: ExecutionSession
  alias Alto.Runner.Result
  alias Alto.Session, as: DurableSession

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-execution-session-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp state(dir, id, opts \\ []) do
    %{
      session: id,
      tool_context: %{session_id: "run-1"},
      session_dir: dir,
      resume_snapshot: Keyword.get(opts, :resume_snapshot, true),
      checkpoint_resume: Keyword.get(opts, :checkpoint_resume, false),
      transcript_revision: Keyword.get(opts, :transcript_revision, 0),
      agent_depth: Keyword.get(opts, :agent_depth, 0),
      max_conversation_bytes: 128_000_000
    }
  end

  defp result(loop_state \\ %{}) do
    %Result{
      output: "done",
      loop_state: loop_state,
      messages: [%{"role" => "user", "content" => "task"}],
      events: [],
      events_dropped: 0,
      verdict: :completed,
      model_requests: 1,
      transcript_bytes: 4,
      session_id: "sess-test",
      run_id: "run-1"
    }
  end

  test "persists transcript and completion", %{dir: dir} do
    id = "sess-events"
    s = state(dir, id)
    assert {:ok, %{persistence: :ok}} = ExecutionSession.persist_outcome(s, {:ok, result()})
    assert {:ok, records} = DurableSession.read(id, session_dir: dir)
    assert Enum.count(records, &(&1["type"] == "completed")) == 1
    assert {:ok, transcript} = DurableSession.transcript(id, session_dir: dir)
    assert transcript.messages == [%{"role" => "user", "content" => "task"}]
  end

  test "suspended checkpoint writes completion without a transcript", %{dir: dir} do
    id = "sess-suspended"
    s = state(dir, id, checkpoint_resume: true)

    assert {:error, :approval_suspended, %{persistence: :ok}} =
             ExecutionSession.persist_outcome(s, {:error, :approval_suspended, result(nil)})

    assert {:ok, records} = DurableSession.read(id, session_dir: dir)
    assert Enum.count(records, &(&1["type"] == "completed")) == 1

    assert {:error, :no_resumable_transcript} = DurableSession.transcript(id, session_dir: dir)
  end

  test "a run without a session preserves existing persistence degradation" do
    s = %{session: nil}

    degraded = %{result() | persistence: {:degraded, [:journal_failed]}}

    assert {:ok, %{persistence: {:degraded, [:journal_failed]}}} =
             ExecutionSession.persist_outcome(s, {:ok, degraded})
  end
end
