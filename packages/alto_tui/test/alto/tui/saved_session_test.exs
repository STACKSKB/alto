defmodule Alto.TUI.SavedSessionTest do
  use ExUnit.Case, async: true
  alias Alto.Session
  alias Alto.Event
  alias Alto.TUI.SavedSession

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-projection-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [session_dir: dir]
    id = Session.generate_id()

    :ok =
      Session.append(
        id,
        Session.started_record(%{
          task: "child",
          subagent: true,
          run_id: "run-a",
          agent_id: "agent-a"
        }),
        opts
      )

    %{
      dir: dir,
      id: id,
      opts: opts,
      path: Path.join(dir, id <> ".jsonl"),
      cache: Path.join([dir, ".cache", id <> ".activity.json"])
    }
  end

  defp usage(id, opts, count) do
    Session.append(
      id,
      Session.event_record(
        "run-a",
        Event.durable(:model_completed, %{
          usage: %{input_tokens: count, output_tokens: 2},
          message: "answer"
        })
      ),
      opts
    )
  end

  test "warm reads and appended records match cold replay without double accounting", %{
    id: id,
    opts: opts,
    cache: cache
  } do
    assert :ok = usage(id, opts, 10)
    assert {:ok, first} = SavedSession.load(id, opts)
    assert first.usage.input_tokens == 10
    assert first.usage.requests == 1
    assert first.agents["agent-a"].activity =~ "answer"
    assert {:ok, ^first} = SavedSession.load(id, opts)
    assert :ok = usage(id, opts, 20)

    assert :ok =
             Session.append(
               id,
               %{"v" => 1, "type" => "completed", "run_id" => "run-a", "status" => "ok"},
               opts
             )

    assert {:ok, appended} = SavedSession.load(id, opts)
    assert appended.usage.input_tokens == 30
    assert appended.usage.requests == 2
    assert appended.agents["agent-a"].status == "ok"
    File.rm!(cache)
    assert {:ok, ^appended} = SavedSession.load(id, opts)
  end

  test "torn tails wait for a newline and corrupt complete records do not poison the cache", %{
    id: id,
    opts: opts,
    path: path
  } do
    assert {:ok, initial} = SavedSession.load(id, opts)

    assert :ok =
             Session.with_lock(id, opts, fn ->
               File.write!(path, ~s({"v":1,"type":"completed","run_id":"run-a","status":"ok"}), [
                 :append
               ])
             end)

    assert {:ok, ^initial} = SavedSession.load(id, opts)
    File.write!(path, "\n", [:append])
    assert {:ok, completed} = SavedSession.load(id, opts)
    assert completed.agents["agent-a"].status == "ok"
    good = File.read!(path)
    File.write!(path, "{broken}\n", [:append])
    assert {:error, :saved_session_corrupt} = SavedSession.load(id, opts)
    File.write!(path, good)
    assert {:ok, ^completed} = SavedSession.load(id, opts)
  end

  test "same-length rewrites, truncation and malformed caches rebuild from authoritative records",
       %{id: id, opts: opts, path: path, cache: cache} do
    assert :ok = usage(id, opts, 10)
    assert {:ok, initial} = SavedSession.load(id, opts)
    assert Map.has_key?(initial.agents, "agent-a")

    assert :ok =
             Session.with_lock(id, opts, fn ->
               File.write!(path, String.replace(File.read!(path), "agent-a", "agent-b"))
             end)

    assert {:ok, changed} = SavedSession.load(id, opts)
    assert Map.has_key?(changed.agents, "agent-b")
    refute Map.has_key?(changed.agents, "agent-a")
    File.write!(cache, ~s({"v":1,"offset":-1}))
    assert {:ok, ^changed} = SavedSession.load(id, opts)
    File.write!(path, "")
    assert {:ok, empty} = SavedSession.load(id, opts)
    assert empty.usage.requests == 0
    assert empty.agents == %{}
    File.rm!(path)
    assert {:error, :enoent} = SavedSession.load(id, opts)
  end

  test "streaming replay keeps records spanning several read chunks", %{
    id: id,
    opts: opts,
    cache: cache
  } do
    assert :ok =
             Session.append(
               id,
               %{"v" => 1, "type" => "padding", "text" => String.duplicate("猫", 80_000)},
               opts
             )

    assert :ok = usage(id, opts, 7)
    assert {:ok, first} = SavedSession.load(id, opts)
    assert first.usage.input_tokens == 7
    assert :ok = usage(id, opts, 11)
    assert {:ok, next} = SavedSession.load(id, opts)
    assert next.usage.input_tokens == 18
    File.rm!(cache)
    assert {:ok, ^next} = SavedSession.load(id, opts)
  end

  test "attempt diagnostics account failed and reduction usage without double counting completion events",
       %{id: id, opts: opts, cache: cache} do
    for usage <- [
          %{input_tokens: 10, output_tokens: 2},
          %{input_tokens: 20, output_tokens: 4},
          nil
        ] do
      assert :ok =
               Session.append(
                 id,
                 Session.diagnostic_record("run-a", :provider_attempt_finished, %{usage: usage}),
                 opts
               )
    end

    assert :ok = usage(id, opts, 20)
    assert {:ok, first} = SavedSession.load(id, opts)
    assert first.usage.input_tokens == 30
    assert first.usage.output_tokens == 6
    assert first.usage.requests == 2
    assert {:ok, ^first} = SavedSession.load(id, opts)
    File.rm!(cache)
    assert {:ok, ^first} = SavedSession.load(id, opts)
  end

  test "legacy attempt diagnostics without accounting preserve completion usage", %{
    id: id,
    opts: opts
  } do
    assert :ok =
             Session.append(
               id,
               Session.diagnostic_record("run-a", :provider_attempt_finished, %{outcome: :ok}),
               opts
             )

    assert :ok = usage(id, opts, 10)
    assert {:ok, projection} = SavedSession.load(id, opts)
    assert projection.usage.input_tokens == 10
    assert projection.usage.requests == 1
  end
end
