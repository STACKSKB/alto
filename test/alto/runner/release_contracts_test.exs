defmodule Alto.Runner.ReleaseContractsTest do
  use ExUnit.Case, async: true
  alias Alto.Event

  defmodule Cycling do
    def init(_, _), do: {:continue, nil, [{:emit, Event.live(:tick, %{})}]}
    def handle_event(_, _, _), do: init(nil, nil)
  end

  defmodule Stuck do
    def init(_, _), do: Process.sleep(:infinity)
    def handle_event(_, _, _), do: nil
  end

  defmodule UnknownTool do
    def name(_opts), do: :remote
    def schema(_opts), do: %{parameters: %{type: "object"}}
    def execution_mode(_opts), do: :exclusive
    def approval(_opts), do: :never
    def run(_, _, _opts), do: {:unknown, :transport_lost}
  end

  defmodule Provider do
    def describe(opts), do: %{context_window: opts[:context_window]}

    def stream(request, _, opts) do
      send(opts[:owner], {:request, request})
      {:ok, %{message: "done", tool_calls: []}}
    end
  end

  defmodule Request do
    def init(task, _), do: {:continue, nil, [{:request_model, task}]}
    def handle_event(%Event{type: :model_completed}, state, _), do: {{:stop, :done}, state, []}
  end

  defmodule Native do
    def name(_opts), do: :native
    def schema(_opts), do: %{parameters: %{type: "object"}}
    def execution_mode(_opts), do: :parallel
    def approval(_opts), do: :never
    def run(arguments, _, _opts), do: {:ok, %{value: arguments["value"]}}
  end

  test "deterministic cycles consume a shared effect budget" do
    assert %Alto.Runner.Result{status: :error, reason: {:effect_limit, 5}} =
             _ =
             Alto.run(%{}, loop: Alto.loop(Cycling), max_effects: 5)
  end

  test "a blocked policy callback cannot outlive the run deadline" do
    assert %Alto.Runner.Result{status: :error, reason: {:participant_failed, :timeout}} =
             _ =
             Alto.run(%{}, loop: Alto.loop(Stuck), run_timeout: 30)
  end

  test "model request options and narrowed tool definitions reach the provider" do
    assert %Alto.Runner.Result{status: :ok} =
             _ =
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
    assert %Alto.Runner.Result{status: :error, reason: {:context_limit, _}} =
             _ =
             Alto.run(String.duplicate("x", 500),
               loop: Alto.chat_loop(context: Alto.Context.Window.new(max_tokens: 50)),
               provider: {Provider, owner: self()}
             )

    refute_receive {:request, _}
  end

  test "context output reservation is enforced on the model request" do
    assert %Alto.Runner.Result{status: :ok} =
             _ =
             Alto.run("go",
               loop:
                 Alto.chat_loop(
                   context: Alto.Context.Window.new(max_tokens: 500, reserve_output: 100)
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

    assert %Alto.Runner.Result{status: :ok} =
             result =
             Alto.run(%{"value" => 42}, loop: Alto.rule_loop(steps: steps), tools: [Native])

    assert result.output == [%{value: 42}, %{value: {:typed, 42}}]
  end
end
