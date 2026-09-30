defmodule Alto.SessionIncrementalTest do
  use ExUnit.Case, async: true
  alias Alto.{Session, Context.Transcript}

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-incremental-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
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
    dir: dir,
    id: id,
    opts: opts
  } do
    large = user(String.duplicate("payload", 20_000))
    {:ok, first} = save(id, [large], opts)

    for n <- 1..20 do
      messages = [large] ++ Enum.map(1..n, &assistant("result #{&1}"))
      assert {:ok, _} = save(id, messages, opts)
    end

    assert length(objects(dir, id, "message")) == 21
    {:ok, latest} = Session.transcript(id, opts)
    assert latest["conversation_bytes"] < first["conversation_bytes"] + 50_000
    assert {:ok, %{"messages" => [^large]}} = Session.conversation(id, 1, opts)
    assert {:ok, _} = save(id, [large, large], opts)
    assert length(objects(dir, id, "message")) == 21
    assert {:ok, %{"messages" => [^large, ^large]}} = Session.transcript(id, opts)
  end

  test "completed reference chunks are shared across appends", %{dir: dir, id: id, opts: opts} do
    messages = [user("start")] ++ Enum.map(1..63, &assistant("row #{&1}"))
    {:ok, one} = save(id, messages, opts)
    {:ok, two} = save(id, messages ++ [assistant("row 64")], opts)
    assert length(objects(dir, id, "node")) == 2

    node =
      File.read!(
        Path.join([dir, "conversations", id, "objects", "node-#{two["message_root"]}.json"])
      )
      |> JSON.decode!()

    assert node["previous"] == one["message_root"]
    assert node["count"] == 65
    assert {:ok, %{"messages" => ^messages}} = Session.conversation(id, 1, opts)
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

  test "legacy migration preserves revisions, fenced effects, and is restartable", %{
    dir: dir,
    id: id,
    opts: opts
  } do
    first = [user("one")]
    second = first ++ [assistant("two")]

    legacy = fn revision, messages ->
      %{
        "v" => 4,
        "session_id" => id,
        "revision" => revision,
        "messages" => messages,
        "transcript_bytes" => Transcript.bytes(messages),
        "settled" => true,
        "dispatch" => nil,
        "parent" =>
          if(revision > 1, do: %{"session_id" => id, "revision" => revision - 1}, else: nil),
        "summary" => nil,
        "context_observation" => nil,
        "retained_bytes_before" => 0
      }
    end

    archive = Path.join([dir, "conversations", id, "revision-1.json"])
    File.mkdir_p!(Path.dirname(archive))
    File.write!(archive, JSON.encode!(legacy.(1, first)))
    fence = %{"revision" => 2, "tool_call_ids" => ["op"], "run_id" => "old-run"}
    File.write!(head(dir, id), JSON.encode!(Map.put(legacy.(2, second), "dispatch", fence)))
    assert {:ok, compacted} = Session.Conversation.compact(id, opts)
    assert compacted["revision"] == 2
    assert compacted["dispatch"] == fence
    assert JSON.decode!(File.read!(archive))["v"] == 5
    assert {:error, {:session_unsettled_tool_dispatch, _}} = Session.transcript(id, opts)
    assert {:ok, %{"messages" => ^first}} = Session.conversation(id, 1, opts)
    assert {:ok, ^compacted} = Session.Conversation.compact(id, opts)

    assert {:ok, %{"revision" => 3}} =
             save(id, second ++ [user("three")], Keyword.put(opts, :resolved_operations, ["op"]))

    assert {:ok, %{"messages" => ^second}} = Session.conversation(id, 2, opts)
  end

  test "ordinary saves automatically convert legacy history", %{dir: dir, id: id, opts: opts} do
    messages = [user("old")]

    legacy = %{
      "v" => 4,
      "session_id" => id,
      "revision" => 1,
      "messages" => messages,
      "transcript_bytes" => Transcript.bytes(messages),
      "settled" => true,
      "dispatch" => nil,
      "parent" => nil,
      "summary" => nil,
      "context_observation" => nil,
      "retained_bytes_before" => 0
    }

    File.write!(head(dir, id), JSON.encode!(legacy))
    assert {:ok, %{"revision" => 2}} = save(id, messages ++ [user("new")], opts)
    assert {:ok, %{"messages" => ^messages, "v" => 5}} = Session.conversation(id, 1, opts)
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

  test "retention option is validated by configuration and persistence", %{id: id, opts: opts} do
    assert Alto.Config.default()[:conversation_retained_turns] == :infinity

    for invalid <- [0, -1, "all", nil] do
      assert {:error, {:invalid_conversation_retained_turns, ^invalid}} =
               save(id, [user("one")], Keyword.put(opts, :conversation_retained_turns, invalid))
    end

    assert {:ok, run} = Alto.Runner.Execution.Setup.open("task", conversation_retained_turns: 7)
    assert run.conversation_retained_turns == 7
  end

  test "message objects preserve Unicode and multimodal structure", %{id: id, opts: opts} do
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

    {:ok, _} = save(id, [message], opts)
    {:ok, _} = save(id, [message, assistant("received")], opts)
    assert {:ok, %{"messages" => [^message]}} = Session.conversation(id, 1, opts)
    assert {:ok, %{"messages" => [^message, _]}} = Session.transcript(id, opts)
  end

  test "continuation hosts share the original user turn identity" do
    alias Alto.Runner.Execution.History
    first = %{session_id: "host-one", agent_identity: %{root_run_id: "user-turn", path: []}}
    resumed = %{first | session_id: "host-two"}
    assert History.turn_id(first) == History.turn_id(resumed)
    assert History.turn_id(%{session_id: "legacy-host"}) == "legacy-host"
  end
end
