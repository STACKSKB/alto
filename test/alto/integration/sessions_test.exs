defmodule Alto.Integration.SessionsTest do
  use ExUnit.Case, async: true
  alias Alto.Runner.Result
  alias Alto.Session

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _, opts) do
      send(opts[:owner], {:request, self(), request.messages})
      if opts[:wait], do: receive(do: (:finish -> :ok))
      {:ok, %{message: "answer", tool_calls: []}}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-sessions-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, opts: [provider: {Provider, owner: self()}, session_dir: dir]}
  end

  test "saved conversations list, page their events, and resume without replaying history", c do
    assert %Result{status: :ok, persistence: :ok} =
             first = Alto.run("first", Keyword.put(c.opts, :session, :new))

    assert_receive {:request, _, [%{"role" => "user", "content" => "first"}]}

    assert %Result{status: :ok, persistence: :ok} =
             second = Alto.resume(first.session_id, "next", c.opts)

    assert second.session_id == first.session_id
    assert first.run_id != second.run_id

    assert_receive {:request, _,
                    [%{"content" => "first"}, %{"content" => "answer"}, %{"content" => "next"}]}

    assert {:ok, records} = Session.read(first.session_id, session_dir: c.dir)
    assert Enum.count(records, &(&1["type"] == "completed")) == 2
    assert {:ok, sessions} = Session.list(session_dir: c.dir)
    assert Enum.any?(sessions, &(&1.id == first.session_id))
    assert {:ok, page} = Session.events(first.session_id, limit: 1, session_dir: c.dir)
    assert length(page.events) == 1

    assert {:ok, later} =
             Session.events(first.session_id, cursor: page.next_cursor, session_dir: c.dir)

    assert later.events != []

    assert {:ok, %{"messages" => messages}} =
             Session.transcript(first.session_id, session_dir: c.dir)

    assert messages == second.messages
  end

  test "competing resumptions publish one conversation and report the losing writer", c do
    assert %Result{status: :ok} = first = Alto.run("first", Keyword.put(c.opts, :session, :new))
    assert_receive {:request, _, _}
    owner = self()

    tasks =
      for task <- ["left", "right"] do
        Task.async(fn ->
          Alto.resume(
            first.session_id,
            task,
            Keyword.put(c.opts, :provider, {Provider, owner: owner, wait: true})
          )
        end)
      end

    assert_receive {:request, one, _}, 2_000
    assert_receive {:request, two, _}, 2_000
    send(one, :finish)
    send(two, :finish)
    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?(%Result{status: :ok, persistence: :ok}, &1)) == 1

    assert [%Result{status: :ok, persistence: {:degraded, errors}}] =
             Enum.filter(results, &(&1.persistence != :ok))

    assert Enum.any?(errors, &match?({:session_conflict, _}, &1))

    assert {:ok, %{"messages" => messages}} =
             Session.transcript(first.session_id, session_dir: c.dir)

    assert Enum.count(messages, &(&1["content"] in ["left", "right"])) == 1
  end

  test "missing history fails explicitly while an unavailable audit store preserves the answer",
       c do
    assert {:error, {:session_not_found, "sess-missing"}} =
             Alto.resume("sess-missing", "next", c.opts)

    assert {:ok, bare} = Session.create("unfinished", %{}, session_dir: c.dir)
    assert {:error, :no_resumable_transcript} = Alto.resume(bare, "next", c.opts)
    assert %Result{status: :ok, session_id: nil} = Alto.run("no persistence", c.opts)
    blocker = Path.join(c.dir, "blocker")
    File.write!(blocker, "not a directory")
    opts = Keyword.merge(c.opts, session: :new, session_dir: Path.join(blocker, "sessions"))

    assert %Result{status: :ok, output: "answer", persistence: {:degraded, [_ | _]}} =
             Alto.run("answer anyway", opts)
  end
end
