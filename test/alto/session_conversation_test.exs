defmodule Alto.SessionConversationTest do
  use ExUnit.Case, async: true

  alias Alto.Context.Transcript
  alias Alto.Session

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-conversation-#{System.unique_integer([:positive])}")
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "kept.txt"), "unchanged")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, workspace: workspace}
  end

  defp user(content), do: %{"role" => "user", "content" => content}

  defp call(id) do
    %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => "write", "arguments" => "{}"}
        }
      ]
    }
  end

  defp reply(id, content \\ "ok"),
    do: %{"role" => "tool", "tool_call_id" => id, "content" => content}

  defp bytes(messages), do: Transcript.bytes(messages)

  test "settled revisions are immutable, parent-linked, and available before completion", %{
    dir: dir
  } do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)
    first = [user("one")]
    second = first ++ [%{"role" => "assistant", "content" => "done"}]

    assert {:ok, one} =
             Session.persist_settled(id, first, bytes(first),
               session_dir: dir,
               expected_revision: 0
             )

    assert one.revision == 1
    assert one.parent == nil
    assert one.settled

    assert {:ok, two} =
             Session.persist_settled(id, second, bytes(second),
               session_dir: dir,
               expected_revision: 1
             )

    assert two.revision == 2
    assert two.parent == %{session_id: id, revision: 1}
    assert two.conversation_bytes > one.conversation_bytes

    assert {:ok, retained_one} = Session.conversation(id, 1, session_dir: dir)
    assert retained_one.messages == first

    assert {:ok, %{messages: ^second, revision: 2}} =
             Session.transcript(id, session_dir: dir)

    assert {:ok, records} = Session.read(id, session_dir: dir)
    refute Enum.any?(records, &(&1["type"] == "completed"))
  end

  test "a dispatch fence blocks an older snapshot and a recovery snapshot closes unknown calls",
       %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)
    safe = [user("perform one effect")]

    assert {:ok, %{revision: 1}} =
             Session.persist_settled(id, safe, bytes(safe),
               session_dir: dir,
               expected_revision: 0
             )

    assert {:ok, _fence} =
             Session.mark_dispatched(id, ["call-1"],
               session_dir: dir,
               expected_revision: 1,
               run_id: "run-crashed"
             )

    assert {:error,
            {:session_unsettled_tool_dispatch,
             %{revision: 1, tool_call_ids: ["call-1"], run_id: "run-crashed"}}} =
             Session.transcript(id, session_dir: dir)

    # Terminal compatibility keeps the assistant call. Setup.close_interrupted/1
    # will turn its missing reply into an explicit unknown result on resume.
    recovery = safe ++ [call("call-1")]

    assert :ok =
             Session.write_transcript(id, recovery, bytes(recovery),
               session_dir: dir,
               expected_revision: 1
             )

    assert {:ok, %{messages: ^recovery, revision: 2}} =
             Session.transcript(id, session_dir: dir)

    assert {:ok, closed} = Transcript.close_interrupted(recovery)
    assert :ok = Transcript.validate(closed)
    assert List.last(closed)["tool_call_id"] == "call-1"
    assert JSON.decode!(List.last(closed)["content"])["outcome"] == "unknown"

    assert {:error, {:conversation_revision_unsettled, ^id, 2}} =
             Session.fork(id, revision: 2, session_dir: dir)
  end

  test "a completed tool group supersedes its dispatch fence", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)
    safe = [user("perform one effect")]
    assert {:ok, _} = Session.persist_settled(id, safe, bytes(safe), session_dir: dir)
    assert {:ok, _} = Session.mark_dispatched(id, ["call-1"], session_dir: dir)

    settled = safe ++ [call("call-1"), reply("call-1")]

    assert {:ok, %{revision: 2, settled: true}} =
             Session.persist_settled(id, settled, bytes(settled),
               session_dir: dir,
               expected_revision: 1
             )

    assert {:ok, %{messages: ^settled, revision: 2}} =
             Session.transcript(id, session_dir: dir)
  end

  test "native dispatch fences require an explicit resolved operation", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)
    safe = [user("run native work")]
    assert {:ok, _} = Session.persist_settled(id, safe, bytes(safe), session_dir: dir)

    assert {:ok, _} =
             Session.mark_dispatched(id, ["op-1"], session_dir: dir, run_id: "run-native")

    assert {:ok, %{tool_call_ids: ["op-1", "op-2"]}} =
             Session.mark_dispatched(id, ["op-2"],
               session_dir: dir,
               run_id: "run-native"
             )

    outcome = safe ++ [user(~s({"type":"alto_native_tool_result","operation_id":"op-1"}))]

    assert {:error,
            {:conversation_unresolved_dispatch, %{revision: 1, operation_ids: ["op-1", "op-2"]}}} =
             Session.persist_settled(id, outcome, bytes(outcome),
               session_dir: dir,
               expected_revision: 1
             )

    assert {:error, {:session_unsettled_tool_dispatch, %{tool_call_ids: ["op-1", "op-2"]}}} =
             Session.transcript(id, session_dir: dir)

    assert {:ok, %{revision: 2}} =
             Session.persist_settled(id, outcome, bytes(outcome),
               session_dir: dir,
               expected_revision: 1,
               resolved_operations: ["op-1", "op-2"]
             )

    assert {:ok, %{messages: ^outcome}} = Session.transcript(id, session_dir: dir)
  end

  test "forks copy only a complete transcript and immutable provenance", %{
    dir: dir,
    workspace: workspace
  } do
    {:ok, source} = Session.create("task", %{}, session_dir: dir)
    first = [user("one")]
    second = first ++ [%{"role" => "assistant", "content" => "two"}]
    assert {:ok, _} = Session.persist_settled(source, first, bytes(first), session_dir: dir)

    assert {:ok, _} =
             Session.persist_settled(source, second, bytes(second),
               session_dir: dir,
               expected_revision: 1
             )

    assert :ok =
             Session.append(
               source,
               %{"v" => 1, "type" => "approval_grant", "secret" => "do-not-copy"},
               session_dir: dir
             )

    assert {:ok, _} =
             Session.mark_dispatched(source, ["pending-source-op"],
               session_dir: dir,
               expected_revision: 2,
               run_id: "run-source"
             )

    assert {:ok, fork} =
             Session.fork(source,
               revision: 1,
               expected_revision: 2,
               session_id: "sess-branch",
               summary: "Explore another approach.",
               session_dir: dir
             )

    assert fork.session_id == "sess-branch"
    assert fork.source == %{session_id: source, revision: 1}
    assert fork.transcript.messages == first
    assert fork.transcript.revision == 1

    assert {:ok, branch_entry} = Session.conversation("sess-branch", 1, session_dir: dir)
    assert branch_entry.parent == %{session_id: source, revision: 1}
    assert branch_entry.summary == "Explore another approach."

    branch_second = first ++ [user("branch only")]

    assert {:ok, branch_head} =
             Session.persist_settled("sess-branch", branch_second, bytes(branch_second),
               session_dir: dir,
               expected_revision: 1
             )

    assert branch_head.parent == %{session_id: "sess-branch", revision: 1}

    assert {:error, {:session_unsettled_tool_dispatch, _}} =
             Session.transcript(source, session_dir: dir)

    assert {:ok, %{messages: ^second}} = Session.conversation(source, :latest, session_dir: dir)

    assert {:ok, %{messages: ^branch_second}} =
             Session.transcript("sess-branch", session_dir: dir)

    assert {:ok, branch_records} = Session.read("sess-branch", session_dir: dir)
    assert Enum.map(branch_records, & &1["type"]) == ["started", "forked"]
    refute Enum.any?(branch_records, &(&1["type"] == "approval_grant"))
    assert File.read!(Path.join(workspace, "kept.txt")) == "unchanged"
  end

  test "revision and aggregate storage fences fail without replacing the head", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)
    first = [user(String.duplicate("a", 80))]
    second = first ++ [user(String.duplicate("b", 80))]

    assert {:ok, one} =
             Session.persist_settled(id, first, bytes(first),
               session_dir: dir,
               expected_revision: 0
             )

    assert {:error, {:session_conflict, %{expected_revision: 0, current_revision: 1}}} =
             Session.persist_settled(id, second, bytes(second),
               session_dir: dir,
               expected_revision: 0
             )

    assert {:error, {:conversation_storage_limit, limit}} =
             Session.persist_settled(id, second, bytes(second),
               session_dir: dir,
               expected_revision: 1,
               max_conversation_bytes: one.conversation_bytes + 1
             )

    assert limit.retained_bytes == one.conversation_bytes
    assert limit.attempted_bytes > limit.max_bytes
    assert {:ok, %{messages: ^first, revision: 1}} = Session.transcript(id, session_dir: dir)

    assert {:error, {:conversation_revision_not_found, ^id, 2}} =
             Session.conversation(id, 2, session_dir: dir)

    assert {:error, {:session_conflict, %{expected_revision: 0, current_revision: 1}}} =
             Session.fork(id,
               expected_revision: 0,
               session_id: "sess-stale-branch",
               session_dir: dir
             )
  end

  test "a missing immutable head fails resume instead of returning a stale transcript", %{
    dir: dir
  } do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)
    messages = [user("hello")]
    {:ok, _} = Session.persist_settled(id, messages, bytes(messages), session_dir: dir)
    File.rm!(Path.join([dir, "conversations", id, "revision-1.json"]))

    assert {:error, {:session_read_failed, {:conversation_revision_not_found, ^id, 1}}} =
             Session.transcript(id, session_dir: dir)
  end
end
