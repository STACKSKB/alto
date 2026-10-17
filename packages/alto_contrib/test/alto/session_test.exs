defmodule Alto.SessionTest do
  use ExUnit.Case, async: true

  alias Alto.Session

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-session-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "events rejects invalid cursors and corrupt trailing records", %{dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    assert {:error, {:invalid_event_cursor, -1}} = Session.events(id, cursor: -1)
    assert {:error, {:invalid_event_limit, 0}} = Session.events(id, limit: 0)
    assert {:error, {:invalid_event_run_id, 12}} = Session.events(id, run_id: 12)

    path = Path.join(dir, id <> ".jsonl")
    assert :ok = File.write(path, "{\"v\":1,\"type\":\"event\"}\n{partial", [:append])

    for reader <- [&Session.read/2, &Session.events/2] do
      assert {:error, {:session_corrupt, ^id, 3}} = reader.(id, session_dir: dir)
    end
  end

  test "log readers handle chunk boundaries, blank lines and an unterminated final record", %{
    dir: dir
  } do
    File.mkdir_p!(dir)
    id = "sess-chunks"
    first = %{"type" => "started", "task" => String.duplicate("界", 30_000)}
    event = %{"type" => "event", "run_id" => "run-a", "data" => "last"}

    File.write!(Path.join(dir, id <> ".jsonl"), [
      "\n",
      JSON.encode!(first),
      "\n\n",
      JSON.encode!(event)
    ])

    assert {:ok, [^first, ^event]} = Session.read(id, session_dir: dir)

    assert {:ok, %{events: [stored], high_watermark: 1, complete: true}} =
             Session.events(id, session_dir: dir)

    assert stored == Map.put(event, "ordinal", 1)
  end

  test "both log readers enforce byte and record limits including non-event records", %{dir: dir} do
    File.mkdir_p!(dir)
    id = "sess-limits"
    path = Path.join(dir, id <> ".jsonl")

    for {contents, reason} <- [
          {String.duplicate("{}\n", 20_001), {:session_too_many_records, id, 20_000}},
          {String.duplicate(" ", 16_000_001), {:session_too_large, id, 16_000_001, 16_000_000}}
        ] do
      File.write!(path, contents)

      for reader <- [&Session.read/2, &Session.events/2] do
        assert {:error, ^reason} = reader.(id, session_dir: dir)
      end
    end
  end

  test "a cursor beyond stored history reports a gap instead of silently accepting it", %{
    dir: dir
  } do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    assert {:ok, %{gap: true, high_watermark: 0}} =
             Session.events(id, session_dir: dir, cursor: 9)
  end

  test "hostile ids never escape the sessions directory", %{dir: dir} do
    for bad <- ["../evil", "a/b", "", "sess ok", 123, nil] do
      assert {:error, {:invalid_session_id, ^bad}} = Session.append(bad, %{}, session_dir: dir)
      assert {:error, {:invalid_session_id, ^bad}} = Session.read(bad, session_dir: dir)
      assert {:error, {:invalid_session_id, ^bad}} = Session.transcript(bad, session_dir: dir)

      assert {:error, {:invalid_session_id, ^bad}} =
               Session.conversation(bad, :latest, session_dir: dir)

      assert {:error, {:invalid_session_id, ^bad}} = Session.fork(bad, :latest, session_dir: dir)
    end

    refute File.exists?(Path.join(dir, "evil"))
  end
end
