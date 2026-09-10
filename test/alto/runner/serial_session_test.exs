defmodule Alto.Runner.SerialSessionTest do
  @moduledoc """
  Session persistence in the serial host: runs record started/durable-event
  snapshots, transcript sidecars, and completions; `Alto.resume/3` continues
  from the latest snapshot with caller-owned composition.
  """

  use ExUnit.Case, async: true

  alias Alto.Session

  defmodule HistoryProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_request, request.messages})
      {:ok, %{message: "done", tool_calls: []}}
    end
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, opts) do
      parent = Keyword.fetch!(opts, :test_pid)
      send(parent, {:resume_waiting, self(), List.last(request.messages)["content"]})

      receive do
        :continue -> {:ok, %{message: Keyword.fetch!(opts, :answer), tool_calls: []}}
      after
        2_000 -> {:error, :release_timeout}
      end
    end
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-serial-session-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp provider_opts, do: [provider: {HistoryProvider, test_pid: self()}, tools: []]

  test "a new session persists the run and reports its ids", %{dir: dir} do
    assert {:ok, result} =
             Alto.run("first task", provider_opts() ++ [session: :new, session_dir: dir])

    assert result.session_id =~ ~r/\Asess-/
    assert result.run_id =~ ~r/\Arun-/
    assert result.output == "done"

    assert {:ok, records} = Session.read(result.session_id, session_dir: dir)
    assert Enum.map(records, & &1["type"]) == ["started", "event", "event", "completed"]

    [started | _] = records
    assert started["run_id"] == result.run_id
    assert started["task"] == "first task"
    assert started["provider"] == "Elixir.Alto.Runner.SerialSessionTest.HistoryProvider"

    completed = List.last(records)
    assert completed["outcome"] == "ok"
    assert completed["model_requests"] == 1

    assert {:ok, %{messages: messages}} = Session.transcript(result.session_id, session_dir: dir)
    assert messages == result.messages
  end

  test "resume continues history with caller-owned composition", %{dir: dir} do
    assert {:ok, first} =
             Alto.run("first task", provider_opts() ++ [session: :new, session_dir: dir])

    assert {:provider_request, first_messages} = receive_request()
    assert [%{"role" => "user", "content" => "first task"}] = first_messages

    assert {:ok, second} =
             Alto.resume(first.session_id, "follow-up", provider_opts() ++ [session_dir: dir])

    assert second.session_id == first.session_id
    assert second.run_id != first.run_id
    assert second.output == "done"

    assert {:provider_request, messages} = receive_request()

    assert [
             %{"role" => "user", "content" => "first task"},
             %{"role" => "assistant", "content" => "done"},
             %{"role" => "user", "content" => "follow-up"}
           ] = messages

    assert {:ok, records} = Session.read(first.session_id, session_dir: dir)
    assert Enum.count(records, &(&1["type"] == "started")) == 2
    assert Enum.count(records, &(&1["type"] == "completed")) == 2
  end

  test "resume of a missing or snapshot-less session fails loudly", %{dir: dir} do
    assert {:error, {:session_not_found, "sess-nope"}} =
             Alto.resume("sess-nope", "task", provider_opts() ++ [session_dir: dir])

    {:ok, bare} = Session.create("crashed", %{}, session_dir: dir)

    assert {:error, :no_resumable_transcript} =
             Alto.resume(bare, "task", provider_opts() ++ [session_dir: dir])
  end

  test "construction failures still report the session id", %{dir: dir} do
    assert {:error, _reason, result} =
             Alto.run("task",
               provider: {HistoryProvider, test_pid: self()},
               tools: [Nope.NotAModule],
               session: :new,
               session_dir: dir
             )

    assert result.session_id =~ ~r/\Asess-/
  end

  test "invalid session options fail closed at construction", %{dir: dir} do
    assert {:error, {:invalid_session_id, "../evil"}, _result} =
             Alto.run("task", provider_opts() ++ [session: "../evil", session_dir: dir])

    assert {:error, {:invalid_session_option, 42}, _result} =
             Alto.run("task", provider_opts() ++ [session: 42, session_dir: dir])

    assert {:error, {:invalid_session_dir, 42}, _result} =
             Alto.run("task", provider_opts() ++ [session_dir: 42])
  end

  test "an explicit session id names its own log", %{dir: dir} do
    assert {:ok, result} =
             Alto.run("task", provider_opts() ++ [session: "sess-explicit", session_dir: dir])

    assert result.session_id == "sess-explicit"
    assert File.exists?(Path.join(dir, "sess-explicit.jsonl"))
  end

  test "unpersisted runs stay silent by default", %{dir: dir} do
    assert {:ok, result} = Alto.run("task", provider_opts() ++ [session_dir: dir])
    assert result.session_id == nil
    assert result.run_id =~ ~r/\Arun-/
    refute File.exists?(dir)
  end

  test "broken session storage never fails the run", %{dir: dir} do
    blocker = Path.join(dir, "blocker")
    File.mkdir_p!(dir)
    File.write!(blocker, "not a directory")

    assert {:ok, result} =
             Alto.run(
               "task",
               provider_opts() ++ [session: :new, session_dir: Path.join(blocker, "sub")]
             )

    assert result.output == "done"
    assert result.session_id =~ ~r/\Asess-/
    assert {:degraded, errors} = result.persistence
    assert errors != []
  end

  test "simultaneous resumes report a stale writer instead of overwriting it", %{dir: dir} do
    assert {:ok, first} =
             Alto.run("first", provider_opts() ++ [session: :new, session_dir: dir])

    assert {:provider_request, _messages} = receive_request()
    parent = self()

    resume = fn follow_up ->
      Alto.resume(first.session_id, follow_up,
        provider: {BlockingProvider, test_pid: parent, answer: "answer-#{follow_up}"},
        tools: [],
        session_dir: dir
      )
    end

    left = Task.async(fn -> resume.("left") end)
    right = Task.async(fn -> resume.("right") end)

    assert_receive {:resume_waiting, left_provider, "left"}
    assert_receive {:resume_waiting, right_provider, "right"}
    send(left_provider, :continue)
    send(right_provider, :continue)

    results = [Task.await(left), Task.await(right)]
    assert Enum.count(results, &match?({:ok, %{persistence: :ok}}, &1)) == 1

    assert [conflicted] =
             Enum.filter(results, &match?({:ok, %{persistence: {:degraded, _}}}, &1))

    assert {:ok, %{persistence: {:degraded, errors}}} = conflicted
    assert Enum.any?(errors, &match?({:session_conflict, _}, &1))

    assert {:ok, %{revision: 2, messages: committed}} =
             Session.transcript(first.session_id, session_dir: dir)

    follow_ups =
      committed
      |> Enum.filter(&(&1["role"] == "user"))
      |> Enum.map(& &1["content"])

    assert Enum.count(follow_ups, &(&1 in ["left", "right"])) == 1
  end

  defp receive_request do
    receive do
      {:provider_request, messages} -> {:provider_request, messages}
    after
      2_000 -> flunk("provider was not called")
    end
  end
end
