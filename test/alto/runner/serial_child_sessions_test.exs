defmodule Alto.Runner.SerialChildSessionsTest do
  use ExUnit.Case, async: true

  alias Alto.{Effect, Event, Session, Transition}

  defmodule BatchLoop do
    @behaviour Alto.Loop
    def init(%{agents: agents}, _),
      do: Transition.continue(%{}, [Effect.spawn_agents(%{agents: agents})])

    def handle_event(%Event{type: :subagents_completed, data: data}, s, _),
      do: Transition.stop(s, {:completed, data.results})

    def handle_event(_, s, _), do: Transition.continue(s)
  end

  defmodule ChildProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_request, _sink, opts),
      do: {:ok, %{message: Keyword.fetch!(opts, :answer), tool_calls: []}}
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-child-sessions-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp loop(sessions),
    do:
      Alto.loop(BatchLoop,
        subagents:
          Alto.Subagents.bounded(
            max_depth: 1,
            max_children: 2,
            max_concurrency: 2,
            sessions: sessions
          )
      )

  defp agents do
    [
      %{id: "one", task: "first", provider: {ChildProvider, answer: "child-one"}},
      %{id: "two", task: "second", provider: {ChildProvider, answer: "child-two"}}
    ]
  end

  test "separate persisted children have independent sessions and parent linkage", %{dir: dir} do
    assert {:ok, parent} =
             Alto.run(%{agents: agents()}, loop: loop(:separate), session: :new, session_dir: dir)

    assert {:completed, results} = parent.output
    assert Enum.map(results, & &1.id) == ["one", "two"]
    child_sessions = Enum.map(results, & &1.session_id)
    assert length(Enum.uniq(child_sessions)) == 2
    assert Enum.all?(child_sessions, &is_binary/1)
    assert Enum.all?(results, &(&1.status == :ok))
    assert parent.persistence == :ok

    assert {:ok, parent_records} = Session.read(parent.session_id, session_dir: dir)
    parent_started = Enum.find(parent_records, &(&1["type"] == "started"))
    child_runs = Enum.map(results, & &1.run_id)
    refute Enum.any?(parent_records, &(&1["run_id"] in child_runs))
    refute parent.session_id in child_sessions

    assert {:ok, sessions} = Session.list(session_dir: dir)
    assert length(sessions) == 3

    Enum.zip(results, agents())
    |> Enum.each(fn {result, assignment} ->
      assert {:ok, records} = Session.read(result.session_id, session_dir: dir)
      started = Enum.find(records, &(&1["type"] == "started"))
      assert started["parent_session_id"] == parent.session_id
      assert started["parent_run_id"] == parent_started["run_id"]
      assert started["run_id"] == result.run_id
      assert started["subagent"] == true
      assert started["session_owner"] == true
      identity = %{"root_run_id" => parent.run_id, "path" => [assignment.id]}
      assert started["agent_identity"] == identity

      assert {:ok, transcript} = Session.transcript(result.session_id, session_dir: dir)

      assert Enum.filter(transcript.messages, &(&1["role"] == "user")) == [
               %{"role" => "user", "content" => assignment.task}
             ]

      assert Enum.filter(transcript.messages, &(&1["role"] == "assistant")) == [
               %{"role" => "assistant", "content" => result.output}
             ]

      assert transcript.revision == 1

      summary = Enum.find(sessions, &(&1.id == result.session_id))
      assert summary.task == assignment.task
      assert summary.runs == 1
      assert summary.completed_runs == 1
      assert summary.last_outcome == "ok"
      assert summary.parent_session_id == parent.session_id
      assert summary.agent_identity == identity
    end)

    assert {:ok, parent_transcript} = Session.transcript(parent.session_id, session_dir: dir)

    refute Enum.any?(
             parent_transcript.messages,
             &(&1["role"] == "assistant" and &1["content"] in ["child-one", "child-two"])
           )
  end

  test "shared remains the default and marks children non-owners", %{dir: dir} do
    assert {:ok, parent} =
             Alto.run(%{agents: agents()},
               loop:
                 Alto.loop(BatchLoop,
                   subagents:
                     Alto.Subagents.bounded(max_depth: 1, max_children: 2, max_concurrency: 2)
                 ),
               session: :new,
               session_dir: dir
             )

    assert {:completed, results} = parent.output
    assert Enum.all?(results, &(&1.session_id == parent.session_id))
    assert {:ok, records} = Session.read(parent.session_id, session_dir: dir)
    children = Enum.filter(records, &(&1["type"] == "started" and &1["subagent"] == true))
    assert length(children) == 2
    assert Enum.all?(children, &(&1["session_owner"] == false))
  end

  test "separate mode does not persist children when parent is nonpersisted", %{dir: dir} do
    assert {:ok, parent} =
             Alto.run(%{agents: agents()}, loop: loop(:separate), session: nil, session_dir: dir)

    assert {:completed, results} = parent.output
    assert Enum.all?(results, &is_nil(&1.session_id))
    assert {:ok, []} = Session.list(session_dir: dir)
  end

  test "invalid session policy is rejected", _context do
    assert_raise ArgumentError, fn ->
      Alto.Subagents.bounded(max_depth: 1, sessions: :isolated)
    end
  end
end
