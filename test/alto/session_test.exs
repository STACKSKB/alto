defmodule Alto.SessionTest do
  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.Session

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-session-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "creates sessions with unique, well-formed ids", %{dir: dir} do
    assert {:ok, first} = Session.create("first task", %{}, session_dir: dir)
    assert {:ok, second} = Session.create("second task", %{}, session_dir: dir)
    assert first != second
    assert first =~ ~r/\Asess-[a-z2-7]+\z/

    assert {:ok, [started]} = Session.read(first, session_dir: dir)

    assert started["type"] == "started"
    assert started["task"] == "first task"
    assert is_integer(started["at_ms"])
  end

  test "started records keep provider identity but never secrets", %{dir: dir} do
    meta = %{
      run_id: "run-1",
      provider: "Elixir.Alto.Providers.OpenAICompatible",
      model: "m",
      cwd: "/tmp"
    }

    assert {:ok, id} = Session.create("task", meta, session_dir: dir)
    assert {:ok, [record]} = Session.read(id, session_dir: dir)
    assert record["provider"] == "Elixir.Alto.Providers.OpenAICompatible"
    assert record["model"] == "m"
    refute Map.has_key?(record, "api_key")
  end

  test "event records round-trip exact terms", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    data = %{
      atom: :approved,
      tuple: {:denied, "nope"},
      nested: [%{deep: {1, :two}}],
      count: 3
    }

    event = Event.durable(:tool_completed, data)
    assert :ok = Session.append(id, Session.event_record("run-9", event), session_dir: dir)

    assert {:ok, [started, stored]} = Session.read(id, session_dir: dir)
    assert started["type"] == "started"
    assert stored["type"] == "event"
    assert stored["domain"] == "durable"
    assert stored["event"] == "tool_completed"
    assert {:ok, ^data} = Session.decode_term(stored["data"])
  end

  test "events paginates by stable ordinal and filters mixed runs", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    for {run_id, type} <- [{"run-a", :one}, {"run-b", :two}, {"run-a", :three}] do
      assert :ok =
               Session.append(id, Session.event_record(run_id, Event.durable(type, %{})),
                 session_dir: dir
               )
    end

    assert {:ok, %{events: [first], next_cursor: 1, complete: false, gap: false}} =
             Session.events(id, session_dir: dir, limit: 1)

    assert first["ordinal"] == 1

    assert {:ok, %{events: [second], next_cursor: nil, complete: true}} =
             Session.events(id, session_dir: dir, cursor: 1, limit: 10, run_id: "run-a")

    assert second["run_id"] == "run-a"
    assert second["ordinal"] == 3
  end

  test "events rejects invalid cursors and corrupt trailing records", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    assert {:error, {:invalid_event_cursor, -1}} = Session.events(id, cursor: -1)
    assert {:error, {:invalid_event_limit, 0}} = Session.events(id, limit: 0)
    assert {:error, {:invalid_event_run_id, 12}} = Session.events(id, run_id: 12)

    path = Path.join(dir, id <> ".jsonl")
    assert :ok = File.write(path, "{\"v\":1,\"type\":\"event\"}\n{partial", [:append])
    assert {:error, {:session_corrupt, ^id, 3}} = Session.events(id, session_dir: dir)
  end

  test "a cursor beyond stored history reports a gap instead of silently accepting it", %{
    dir: dir
  } do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    assert {:ok, %{gap: true, high_watermark: 0}} =
             Session.events(id, session_dir: dir, cursor: 9)
  end

  test "completed and compaction records persist outcomes", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    assert :ok =
             Session.append(
               id,
               Session.completed_record(%{
                 run_id: "run-1",
                 outcome: "error",
                 reason: {:model_request_failed, :boom},
                 output: nil,
                 model_requests: 4
               }),
               session_dir: dir
             )

    assert :ok =
             Session.append(
               id,
               Session.compaction_record(%{
                 run_id: "run-1",
                 dropped_messages: 12,
                 dropped_bytes: 9000,
                 summary_bytes: 400,
                 summary: "did things"
               }),
               session_dir: dir
             )

    assert {:ok, [_started, completed, compaction]} = Session.read(id, session_dir: dir)
    assert completed["outcome"] == "error"
    assert {:ok, {:model_request_failed, :boom}} = Session.decode_term(completed["reason"])
    assert compaction["summary"] == "did things"
    assert compaction["dropped_messages"] == 12
  end

  test "transcript sidecar round-trips; missing sidecar is explicit", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    messages = [
      %{"role" => "user", "content" => "hi"},
      %{"role" => "assistant", "content" => "yo"}
    ]

    assert :ok = Session.write_transcript(id, messages, 42, session_dir: dir)

    assert {:ok, %{messages: ^messages, transcript_bytes: 42, revision: 1}} =
             Session.transcript(id, session_dir: dir)

    {:ok, bare} = Session.create("other", %{}, session_dir: dir)
    assert {:error, :no_resumable_transcript} = Session.transcript(bare, session_dir: dir)
  end

  test "overwriting the sidecar is atomic and leaves no temp litter", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    first = [%{"role" => "user", "content" => "hi"}]
    assert :ok = Session.write_transcript(id, first, 20, session_dir: dir)

    second = first ++ [%{"role" => "assistant", "content" => "done"}]
    assert :ok = Session.write_transcript(id, second, 55, session_dir: dir)

    assert {:ok, %{messages: ^second, transcript_bytes: 55, revision: 2}} =
             Session.transcript(id, session_dir: dir)

    # A crash between the temp write and the rename leaves the previous
    # snapshot intact; a successful write leaves no temp siblings behind.
    litter = File.ls!(dir) |> Enum.filter(&String.contains?(&1, ".alto-"))
    assert litter == []
  end

  test "revision checks prevent a stale snapshot overwrite", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)
    first = [%{"role" => "user", "content" => "first"}]
    second = [%{"role" => "user", "content" => "second"}]

    assert :ok =
             Session.write_transcript(id, first, 20,
               session_dir: dir,
               expected_revision: 0
             )

    assert {:error,
            {:session_conflict, %{session_id: ^id, expected_revision: 0, current_revision: 1}}} =
             Session.write_transcript(id, second, 21,
               session_dir: dir,
               expected_revision: 0
             )

    assert {:ok, %{messages: ^first, revision: 1}} =
             Session.transcript(id, session_dir: dir)
  end

  test "hostile ids never escape the sessions directory", %{dir: dir} do
    for bad <- ["../evil", "a/b", "", "sess ok", 123, nil] do
      assert {:error, {:invalid_session_id, ^bad}} = Session.append(bad, %{}, session_dir: dir)
      assert {:error, {:invalid_session_id, ^bad}} = Session.read(bad, session_dir: dir)
      assert {:error, {:invalid_session_id, ^bad}} = Session.transcript(bad, session_dir: dir)
    end

    refute File.exists?(Path.join(dir, "evil"))
  end

  test "missing sessions and corrupt lines fail loudly", %{dir: dir} do
    assert {:error, {:session_not_found, "sess-missing"}} =
             Session.read("sess-missing", session_dir: dir)

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "sess-broken.jsonl"), "{not json\n")

    assert {:error, {:session_corrupt, "sess-broken", 1}} =
             Session.read("sess-broken", session_dir: dir)
  end

  test "unencodable payloads fail closed at the boundary", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    assert {:error, {:session_unencodable, _}} =
             Session.append(id, %{"bad" => <<255, 255>>}, session_dir: dir)
  end

  test "list summarizes newest-first and ignores non-session files", %{dir: dir} do
    {:ok, first} = Session.create("first", %{}, session_dir: dir)
    Process.sleep(5)
    {:ok, second} = Session.create("second", %{}, session_dir: dir)

    File.write!(Path.join(dir, "notes.txt"), "not a session")

    assert {:ok, [newest, oldest]} = Session.list(session_dir: dir)
    assert newest.id == second
    assert oldest.id == first
    assert newest.task == "second"
    assert newest.runs == 1
    assert newest.completed_runs == 0
    assert newest.last_outcome == nil
    assert is_integer(newest.started_at_ms)
  end

  test "list on a missing directory is empty", %{dir: dir} do
    assert {:ok, []} = Session.list(session_dir: Path.join(dir, "nope"))
  end

  test "decode_term rejects garbage",
    do: assert({:error, _} = Session.decode_term(%{"nope" => 1}))
end
