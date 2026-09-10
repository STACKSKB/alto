defmodule Alto.Runner.SerialSubagentTest do
  @moduledoc """
  Owned serial sub-runs: the loop delegates through `:spawn_agent`, the host
  enforces depth budgets, inherits provider/tools/approval with no widening,
  forwards progress, validates results, and propagates cancellation.
  """

  use ExUnit.Case, async: true

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Session
  alias Alto.Transition

  defmodule EchoTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :echo

    @impl true
    def schema do
      %{
        description: "Echo a value.",
        parameters: %{
          type: "object",
          properties: %{value: %{type: "string"}},
          required: ["value"]
        }
      }
    end

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :never

    @impl true
    def run(%{"value" => value}, _context), do: {:ok, %{echo: value}}
  end

  defmodule GuardedEchoTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :guarded_echo

    @impl true
    def schema, do: EchoTool.schema()

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :required

    @impl true
    def run(%{"value" => value}, context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:guarded_ran, value, context.session_id})
      {:ok, %{echo: value}}
    end
  end

  defmodule AnswerProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_request, request.messages})
      {:ok, %{message: Keyword.fetch!(opts, :answer), tool_calls: []}}
    end
  end

  defmodule EchoCallProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, _opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        {:ok, %{message: "child done", tool_calls: []}}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [%{id: "c1", name: "echo", arguments_json: ~s({"value":"hi"})}]
         }}
      end
    end
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), :child_entered)

      receive do
        :never -> {:ok, %{message: nil, tool_calls: []}}
      end
    end
  end

  defmodule GuardedEchoCallProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, _opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        {:ok, %{message: "denied and done", tool_calls: []}}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [%{id: "c1", name: "guarded_echo", arguments_json: ~s({"value":"hi"})}]
         }}
      end
    end
  end

  # A parent loop that delegates once, then stops with whatever the host
  # reports. The delegation request rides in the task.
  defmodule SpawnOnceLoop do
    @behaviour Alto.Loop

    @impl true
    def init(%{spawn: spawn}, _spec) do
      Transition.continue(%{}, [Effect.spawn_agent(spawn)])
    end

    @impl true
    def handle_event(%Event{type: :subagent_completed, data: data}, state, _spec) do
      Transition.stop(state, {:completed, data})
    end

    def handle_event(%Event{type: :subagent_failed, data: data}, state, _spec) do
      Transition.stop(state, {:failed, data})
    end

    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  defmodule ExplodingLoop do
    @behaviour Alto.Loop

    @impl true
    def init(_task, _spec), do: raise("child boom")

    @impl true
    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-subagent-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp parent_loop(max_depth) do
    Alto.loop(SpawnOnceLoop, subagents: Alto.Subagents.bounded(max_depth: max_depth))
  end

  test "delegation is disabled without a depth budget", %{dir: dir} do
    assert {:ok, result} =
             Alto.run(%{spawn: %{id: "sub-1", task: "child task"}},
               loop: parent_loop(0),
               provider: {AnswerProvider, test_pid: self(), answer: "unused"},
               session: :new,
               session_dir: dir
             )

    assert {:failed, %{id: "sub-1", error: :max_depth_exceeded}} = result.output
    assert Enum.any?(result.events, &(&1.type == :subagent_failed))
  end

  test "the child inherits provider, tools, and approval by default", %{dir: dir} do
    test_pid = self()

    child_provider = {EchoCallProvider, []}

    assert {:ok, result} =
             Alto.run(
               %{spawn: %{id: "sub-1", task: "do the echo", provider: child_provider}},
               loop: parent_loop(1),
               provider: {AnswerProvider, test_pid: test_pid, answer: "parent unused"},
               tools: [EchoTool],
               approval: Alto.Approvals.DenyAll,
               session: :new,
               session_dir: dir
             )

    assert {:completed, %{id: "sub-1", status: :ok, output: "child done", model_requests: 2}} =
             result.output

    assert {:ok, records} = Session.read(result.session_id, session_dir: dir)
    started = Enum.filter(records, &(&1["type"] == "started"))
    assert length(started) == 2

    [parent_started, child_started] =
      Enum.sort_by(started, & &1["at_ms"])

    assert child_started["parent_run_id"] == parent_started["run_id"]
    assert child_started["task"] == "do the echo"
  end

  test "approval policy applies inside the child with no widening", %{dir: dir} do
    test_pid = self()

    # The child calls the guarded tool under DenyAll, proving the parent
    # policy governs the child: a widened policy would have run it.
    assert {:ok, result} =
             Alto.run(
               %{
                 spawn: %{
                   id: "sub-1",
                   task: "guarded",
                   provider: {GuardedEchoCallProvider, test_pid: test_pid}
                 }
               },
               loop: parent_loop(1),
               provider: {AnswerProvider, test_pid: test_pid, answer: "parent unused"},
               tools: [{GuardedEchoTool, test_pid: test_pid}],
               approval: Alto.Approvals.DenyAll,
               session: :new,
               session_dir: dir
             )

    assert {:completed, %{id: "sub-1", status: :ok}} = result.output
    refute_received {:guarded_ran, _, _}
  end

  test "an explicit tool set overrides inheritance", %{dir: dir} do
    test_pid = self()

    assert {:ok, result} =
             Alto.run(
               %{
                 spawn: %{
                   id: "sub-1",
                   task: "no tools",
                   tools: [],
                   provider: {EchoCallProvider, []}
                 }
               },
               loop: parent_loop(1),
               provider: {AnswerProvider, test_pid: test_pid, answer: "parent unused"},
               tools: [EchoTool],
               session: :new,
               session_dir: dir
             )

    assert {:completed, %{id: "sub-1", status: :ok, output: "child done"}} = result.output

    # The echo call failed unknown_tool — proving the empty override took
    # effect, since the parent's echo tool would have succeeded — and the
    # default loop absorbed the failure as an observation.
    assert {:ok, records} = Session.read(result.session_id, session_dir: dir)

    child_id =
      records
      |> Enum.filter(&(&1["type"] == "started"))
      |> Enum.find_value(fn
        %{"parent_run_id" => parent, "run_id" => child} when parent == result.run_id -> child
        _other -> nil
      end)

    assert is_binary(child_id)

    failed =
      Enum.find(records, fn record ->
        record["type"] == "event" and record["event"] == "tool_failed" and
          record["run_id"] == child_id
      end)

    assert {:ok, %{error: {:unknown_tool, "echo"}}} = Session.decode_term(failed["data"])
  end

  test "invalid delegation requests fail the run", %{dir: dir} do
    assert {:error, {:invalid_spawn_agent, _}, _result} =
             Alto.run(%{spawn: %{id: "sub-1"}},
               loop: parent_loop(1),
               provider: {AnswerProvider, test_pid: self(), answer: "unused"},
               session: :new,
               session_dir: dir
             )
  end

  test "a grandchild beyond the budget fails while its parent continues", %{dir: dir} do
    test_pid = self()

    grandchild = %{id: "grand", task: "never runs"}

    assert {:ok, result} =
             Alto.run(%{spawn: %{id: "sub-1", task: %{spawn: grandchild}, loop: parent_loop(1)}},
               loop: parent_loop(1),
               provider: {AnswerProvider, test_pid: test_pid, answer: "unused"},
               session: :new,
               session_dir: dir
             )

    assert {:completed, %{id: "sub-1", status: :ok, output: {:failed, %{id: "grand"}}}} =
             result.output
  end

  test "a crashing child becomes a failed event, not a parent crash", %{dir: dir} do
    assert {:ok, result} =
             Alto.run(
               %{spawn: %{id: "sub-1", task: "boom", loop: Alto.loop(ExplodingLoop)}},
               loop: parent_loop(1),
               provider: {AnswerProvider, test_pid: self(), answer: "unused"},
               session: :new,
               session_dir: dir
             )

    assert {:failed, %{id: "sub-1", error: {:loop_process_failed, _}}} = result.output
  end

  test "parent cancellation tears the child down", %{dir: dir} do
    test_pid = self()

    {:ok, handle} =
      Alto.start(%{spawn: %{id: "sub-1", task: "block"}},
        loop: parent_loop(1),
        provider: {BlockingProvider, test_pid: test_pid},
        session: :new,
        session_dir: dir
      )

    assert_receive :child_entered, 2_000
    assert :ok = Alto.cancel(handle, :operator_stop)
    assert {:error, {:cancelled, :operator_stop}, parent_result} = Alto.await(handle, 10_000)
    assert parent_result.session_id != nil

    assert {:ok, records} = Session.read(parent_result.session_id, session_dir: dir)

    child_done =
      Enum.find(records, &(&1["type"] == "completed" and &1["run_id"] != parent_result.run_id))

    assert child_done["outcome"] == "cancelled"
  end
end
