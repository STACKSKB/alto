defmodule Alto.SessionIncrementalTest do
  use ExUnit.Case, async: true
  alias Alto.Session
  alias Alto.Context.Transcript

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    {:ok, id} = Session.create("incremental", %{}, session_dir: dir)
    %{dir: dir, id: id, opts: [session_dir: dir]}
  end

  defp user(text), do: %{"role" => "user", "content" => text}
  defp assistant(text), do: %{"role" => "assistant", "content" => text}

  defp save(id, messages, opts),
    do: Session.persist_settled(id, messages, Transcript.bytes(messages), opts)

  defp objects(dir, id, kind),
    do: Path.wildcard(Path.join([dir, "conversations", id, "objects", "#{kind}-*.json"]))

  defp head(dir, id), do: Path.join(dir, id <> ".transcript.json")

  test "large unchanged prefixes are stored once, including repeated message occurrences", %{
    id: id,
    opts: opts
  } do
    large = user(String.duplicate("payload", 20_000))
    {:ok, first} = save(id, [large], opts)

    for n <- 1..20 do
      messages = [large] ++ Enum.map(1..n, &assistant("result #{&1}"))
      assert {:ok, _} = save(id, messages, opts)
    end

    {:ok, latest} = Session.transcript(id, opts)
    assert latest["conversation_bytes"] < first["conversation_bytes"] + 50_000
    assert {:ok, %{"messages" => [^large]}} = Session.conversation(id, 1, opts)
    assert {:ok, _} = save(id, [large, large], opts)
    assert {:ok, %{"messages" => [^large, ^large]}} = Session.transcript(id, opts)
  end

  test "archive conflicts reject a save before publishing objects or advancing the head", %{
    dir: dir,
    id: id,
    opts: opts
  } do
    first = [user("first")]
    {:ok, _} = save(id, first, opts)
    original = File.read!(head(dir, id))
    existing = objects(dir, id, "*")
    archive = Path.join([dir, "conversations", id, "revision-1.json"])

    for conflicting <- ["", "conflicting archive"] do
      File.write!(archive, conflicting)

      assert {:error, {:conversation_revision_conflict, %{session_id: ^id, revision: 1}}} =
               save(id, first ++ [assistant("next")], opts)

      assert File.read!(head(dir, id)) == original
      assert File.read!(archive) == conflicting
      assert objects(dir, id, "*") == existing
    end

    File.rm!(archive)
    assert {:ok, %{"revision" => 2}} = save(id, first ++ [assistant("next")], opts)
    assert {:ok, %{"messages" => ^first}} = Session.conversation(id, 1, opts)
    assert Bitwise.band(File.stat!(archive).mode, 0o777) == 0o600
  end

  test "retention groups all model boundaries in a turn, and keeps current context", %{
    dir: dir,
    id: id,
    opts: opts
  } do
    opts = Keyword.put(opts, :conversation_retained_turns, 2)
    first = [user("one")]
    {:ok, _} = save(id, first, Keyword.put(opts, :conversation_turn_id, "turn-one"))
    first = first ++ [assistant("one result")]
    {:ok, _} = save(id, first, Keyword.put(opts, :conversation_turn_id, "turn-one"))
    second = first ++ [user("two")]
    {:ok, _} = save(id, second, Keyword.put(opts, :conversation_turn_id, "turn-two"))
    second = second ++ [assistant("two result")]
    {:ok, _} = save(id, second, Keyword.put(opts, :conversation_turn_id, "turn-two"))
    third = second ++ [user("three")]
    {:ok, latest} = save(id, third, Keyword.put(opts, :conversation_turn_id, "turn-three"))
    assert latest["turn"] == 3

    for revision <- [1, 2],
        do:
          assert(
            {:error, {:conversation_revision_not_found, ^id, ^revision}} =
              Session.conversation(id, revision, opts)
          )

    assert {:ok, %{"messages" => ^second}} = Session.conversation(id, 4, opts)
    assert {:ok, %{"messages" => ^third}} = Session.transcript(id, opts)
    assert length(objects(dir, id, "message")) == 5
    assert File.stat!(head(dir, id)).size < 1000
  end

  test "context reduction prunes only unreachable objects and never changes turn identity", %{
    dir: dir,
    id: id,
    opts: opts
  } do
    opts = Keyword.put(opts, :conversation_retained_turns, 1)
    old = [user("huge old turn"), assistant("old result")]
    {:ok, _} = save(id, old, Keyword.put(opts, :conversation_turn_id, "one"))
    second = old ++ [user("continue")]
    {:ok, _} = save(id, second, Keyword.put(opts, :conversation_turn_id, "two"))
    reduced = [user("summary"), assistant("new result")]
    {:ok, snapshot} = save(id, reduced, Keyword.put(opts, :conversation_turn_id, "two"))
    assert snapshot["turn"] == 2
    assert length(objects(dir, id, "message")) == 5
    # All revisions within turn two remain available until a later user turn.
    {:ok, final} =
      save(id, reduced ++ [user("next")], Keyword.put(opts, :conversation_turn_id, "three"))

    assert final["turn"] == 3
    assert length(objects(dir, id, "message")) == 3
    assert {:ok, _} = Session.transcript(id, opts)
  end

  test "compaction preserves revisions and dispatch fences and is repeatable", %{
    dir: dir,
    id: id,
    opts: opts
  } do
    first = [user("one")]
    second = first ++ [assistant("two")]
    {:ok, _} = save(id, first, opts)
    {:ok, _} = save(id, second, opts)
    {:ok, fence} = Session.mark_dispatched(id, ["op"], Keyword.put(opts, :run_id, "run"))
    archive = Path.join([dir, "conversations", id, "revision-1.json"])
    encoded = File.read!(archive)

    assert {:ok, compacted} = Session.Conversation.compact(id, opts)
    assert compacted["revision"] == 2
    assert compacted["dispatch"] == fence
    assert File.read!(archive) == encoded
    assert {:error, {:session_unsettled_tool_dispatch, _}} = Session.transcript(id, opts)
    assert {:ok, %{"messages" => ^first}} = Session.conversation(id, 1, opts)
    assert {:ok, ^compacted} = Session.Conversation.compact(id, opts)

    assert {:ok, %{"revision" => 3}} =
             save(id, second ++ [user("three")], Keyword.put(opts, :resolved_operations, ["op"]))

    assert {:ok, %{"messages" => ^second}} = Session.conversation(id, 2, opts)
  end

  test "old heads and archives are rejected without rewriting saved data", %{
    dir: dir,
    id: id,
    opts: opts
  } do
    messages = [user("old")]
    {:ok, snapshot} = save(id, messages, opts)
    original = File.read!(head(dir, id))

    legacy =
      snapshot
      |> Map.drop(~w(message_root message_count turn turn_id retained_turns conversation_bytes))
      |> Map.put("v", 4)
      |> JSON.encode!()

    File.write!(head(dir, id), legacy)

    assert {:error, {:session_corrupt, ^id, :transcript}} = Session.transcript(id, opts)

    assert {:error, {:session_corrupt, ^id, :transcript}} =
             save(id, messages ++ [user("new")], opts)

    assert {:error, {:session_corrupt, ^id, :transcript}} = Session.Conversation.compact(id, opts)
    assert File.read!(head(dir, id)) == legacy

    File.write!(head(dir, id), original)
    {:ok, _} = save(id, messages ++ [user("new")], opts)
    current = File.read!(head(dir, id))
    archive = Path.join([dir, "conversations", id, "revision-1.json"])
    File.write!(archive, legacy)

    assert {:error, {:conversation_corrupt, ^id, 1}} = Session.conversation(id, 1, opts)

    assert {:error, {:conversation_corrupt, ^id, :retention}} =
             Session.Conversation.compact(id, opts)

    assert File.read!(head(dir, id)) == current
    assert File.read!(archive) == legacy
  end

  test "missing or altered objects and malicious references fail closed", %{
    dir: dir,
    id: id,
    opts: opts
  } do
    {:ok, _} = save(id, [user("one")], opts)
    [object] = objects(dir, id, "message")
    encoded = File.read!(object)
    File.write!(object, JSON.encode!(user("altered")))
    assert {:error, {:session_corrupt, ^id, :transcript}} = Session.transcript(id, opts)
    File.write!(object, encoded)
    record = JSON.decode!(File.read!(head(dir, id)))
    File.write!(head(dir, id), JSON.encode!(Map.put(record, "message_root", "../../outside")))
    assert {:error, {:session_corrupt, ^id, :transcript}} = Session.transcript(id, opts)
    File.write!(head(dir, id), JSON.encode!(record))
    File.rm!(object)
    assert {:error, {:session_corrupt, ^id, :transcript}} = Session.transcript(id, opts)
  end

  test "a fork remains independent when source objects are reclaimed", %{
    dir: dir,
    id: id,
    opts: opts
  } do
    first = [user("source")]
    {:ok, _} = save(id, first, opts)
    {:ok, branch} = Session.fork(id, 1, opts)
    finite = Keyword.put(opts, :conversation_retained_turns, 1)
    {:ok, _} = save(id, [user("replacement")], finite)
    refute Enum.any?(objects(dir, id, "message"), &(File.read!(&1) == JSON.encode!(hd(first))))
    assert {:ok, %{"messages" => ^first}} = Session.transcript(branch.session_id, opts)
  end

  test "native fence resolution advances even when message content is unchanged", %{
    id: id,
    opts: opts
  } do
    messages = [user("work")]
    {:ok, _} = save(id, messages, opts)
    {:ok, _} = Session.mark_dispatched(id, ["native"], opts)
    assert {:error, {:conversation_unresolved_dispatch, _}} = save(id, messages, opts)

    assert {:ok, %{"revision" => 2, "dispatch" => nil}} =
             save(id, messages, Keyword.put(opts, :resolved_operations, ["native"]))
  end

  test "invalid retention limits are rejected by persistence", %{id: id, opts: opts} do
    for invalid <- [0, -1, "all", nil] do
      assert {:error, {:invalid_conversation_retained_turns, ^invalid}} =
               save(id, [user("one")], Keyword.put(opts, :conversation_retained_turns, invalid))
    end
  end

  test "message objects preserve Unicode, uploaded files, and generated artifacts", %{
    dir: dir,
    id: id,
    opts: opts
  } do
    message = %{
      "role" => "user",
      "content" => [
        %{"type" => "text", "text" => "猫 👋 café\n"},
        %{
          "type" => "image_url",
          "image_url" => %{"url" => "data:image/png;base64,YQ==", "detail" => "high"}
        }
      ]
    }

    alias Alto.Content

    input = %{
      "role" => "user",
      "content" => [
        Content.file(
          "report.pdf",
          "application/pdf",
          Base.encode64(String.duplicate("%PDF-1.7 input", 5_000))
        )
      ]
    }

    output = %{
      "role" => "assistant",
      "content" => [
        Content.artifact(
          "answer.docx",
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
          Base.encode64(<<80, 75, 0, 255>>)
        )
      ]
    }

    messages = [message, input, output]
    {:ok, _} = save(id, messages, opts)
    {:ok, _} = save(id, messages ++ [assistant("received")], opts)
    assert {:ok, %{"messages" => ^messages}} = Session.conversation(id, 1, opts)
    assert {:ok, %{"messages" => latest}} = Session.transcript(id, opts)
    assert latest == messages ++ [assistant("received")]
    assert length(objects(dir, id, "message")) == 4

    assert {:ok, %Content{blocks: blocks}} =
             Content.decode_transcript(Enum.at(latest, 1)["content"])

    assert blocks == input["content"]
  end

  test "continuation hosts share the original user turn identity" do
    alias Alto.Runner.Execution.History
    first = %{session_id: "host-one", agent_identity: %{root_run_id: "user-turn", path: []}}
    resumed = %{first | session_id: "host-two"}
    assert History.turn_id(first) == History.turn_id(resumed)
    assert History.turn_id(%{session_id: "legacy-host"}) == "legacy-host"
  end
end
