defmodule Alto.Runner.ReleaseContractsTest do
  use ExUnit.Case, async: true
  alias Alto.{Effect, Event, Transition}

  defmodule Cycling do
    def init(_, _), do: Transition.continue(nil, [Effect.emit(Event.live(:tick, %{}))])
    def handle_event(_, _, _), do: init(nil, nil)
  end

  defmodule Stuck do
    def init(_, _), do: Process.sleep(:infinity)
    def handle_event(_, _, _), do: nil
  end

  defmodule UnknownTool do
    def name, do: :remote
    def schema, do: %{parameters: %{type: "object"}}
    def execution_mode, do: :exclusive
    def approval, do: :never
    def run(_, _), do: {:unknown, :transport_lost}
  end

  defmodule Provider do
    def describe(opts), do: %{context_window: opts[:context_window]}

    def stream(request, _, opts) do
      send(opts[:owner], {:request, request})
      {:ok, %{message: "done", tool_calls: []}}
    end
  end

  defmodule Request do
    def init(task, _), do: Transition.continue(nil, [Effect.request_model(task)])
    def handle_event(%Event{type: :model_completed}, state, _), do: Transition.stop(state, :done)
  end

  defmodule Native do
    def name, do: :native
    def schema, do: %{parameters: %{type: "object"}}
    def execution_mode, do: :parallel
    def approval, do: :never
    def run(arguments, _), do: {:ok, %{value: arguments["value"]}}
  end

  defmodule Parent do
    def init(_, _),
      do:
        Transition.continue(nil, [
          Effect.spawn_agent(%{
            id: "child",
            task: %{"value" => 42},
            loop: Alto.rule_loop(steps: ["native"])
          })
        ])

    def handle_event(%Event{type: :subagent_completed, data: data}, state, _),
      do: Transition.stop(state, data.output)

    def handle_event(%Event{type: :subagent_failed, data: data}, state, _),
      do: Transition.error(state, data.error)
  end

  test "deterministic cycles consume a shared effect budget" do
    assert {:error, {:effect_limit, 5}, _} =
             Alto.run(%{}, loop: Alto.loop(Cycling), max_effects: 5)
  end

  test "a blocked policy callback cannot outlive the run deadline" do
    assert {:error, {:loop_process_failed, :timeout}, _} =
             Alto.run(%{}, loop: Alto.loop(Stuck), run_timeout: 30)
  end

  test "transport uncertainty survives the native tool and result boundary" do
    assert {:error, _, result} =
             Alto.run(%{}, loop: Alto.rule_loop(steps: ["remote"]), tools: [UnknownTool])

    assert result.verdict == :unknown

    assert Enum.any?(
             result.events,
             &match?(%Event{type: :tool_failed, data: %{outcome: :unknown}}, &1)
           )
  end

  test "model request options and narrowed tool definitions reach the provider" do
    assert {:ok, _} =
             Alto.run(
               %{
                 options: %{"temperature" => 0, "response_format" => %{"type" => "json_object"}},
                 model_tools: []
               },
               loop: Alto.loop(Request),
               tools: [UnknownTool],
               provider: {Provider, owner: self()}
             )

    assert_receive {:request,
                    %{
                      tools: [],
                      options: %{
                        "temperature" => 0,
                        "response_format" => %{"type" => "json_object"}
                      }
                    }}
  end

  test "context policy rejects excess input before provider dispatch" do
    assert {:error, {:context_limit, _}, _} =
             Alto.run(String.duplicate("x", 500),
               loop: Alto.chat_loop(context: Alto.Context.window(max_tokens: 50)),
               provider: {Provider, owner: self()}
             )

    refute_receive {:request, _}
  end

  test "context output reservation is enforced on the model request" do
    assert {:ok, _} =
             Alto.run("go",
               loop:
                 Alto.chat_loop(
                   context: Alto.Context.window(max_tokens: 500, reserve_output: 100)
                 ),
               provider: {Provider, owner: self()}
             )

    assert_receive {:request, %{options: %{"max_tokens" => 100}}}
  end

  test "native step results compose without a JSON round trip" do
    steps = [
      "native",
      %{tool: "native", arguments: fn _task, [first] -> %{"value" => {:typed, first.value}} end}
    ]

    assert {:ok, result} =
             Alto.run(%{"value" => 42}, loop: Alto.rule_loop(steps: steps), tools: [Native])

    assert result.output == [%{value: 42}, %{value: {:typed, 42}}]
  end

  test "a providerless parent can delegate to a deterministic child" do
    assert {:ok, result} =
             Alto.run(%{},
               loop: Alto.loop(Parent, subagents: Alto.Subagents.bounded(max_depth: 1)),
               tools: [Native]
             )

    assert result.output == [%{value: 42}]
  end
end
