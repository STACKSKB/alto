defmodule Alto.Loops.DefaultTest do
  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.Loop

  test "starts by requesting a model response" do
    context = Alto.Context.Window.new(max_tokens: 200_000, reserve_output: 16_000)
    spec = Alto.default_loop(context: context)

    assert {:continue, %{phase: :awaiting_model},
            [{:request_model, %{task: "fix the parser", step: 1, context: ^context}}]} =
             spec.driver.init("fix the parser", spec)
  end

  test "waits for all tools, settles the step, then requests the model again" do
    spec = Alto.default_loop()
    {:continue, initial, _} = spec.driver.init("inspect the repository", spec)

    model =
      Event.durable(:model_completed, %{
        message: %{role: :assistant},
        tool_calls: [
          %{id: "call-1", name: :rg, arguments: %{pattern: "TODO"}},
          %{id: "call-2", name: :git_diff, arguments: %{}}
        ]
      })

    assert {:continue, tools, [{:run_tool, _}, {:run_tool, _}]} =
             Loop.dispatch(spec, model, initial)

    assert {:continue, first_result, []} =
             Loop.dispatch(
               spec,
               Event.durable(:tool_completed, %{call_id: "call-1", result: "matches"}),
               tools
             )

    assert {:continue, second_result, [{:emit, %Event{type: :step_settled} = settled}]} =
             Loop.dispatch(
               spec,
               Event.durable(:tool_completed, %{call_id: "call-2", result: "diff"}),
               first_result
             )

    assert {:continue, %{step: 2}, [{:request_model, %{step: 2, observations: observations}}]} =
             Loop.dispatch(spec, settled, second_result)

    assert Enum.map(observations, & &1.data.call_id) == ["call-1", "call-2"]
  end

  test "a final model response stops only after the step-settled boundary" do
    spec = Alto.default_loop()
    {:continue, initial, _} = spec.driver.init("answer briefly", spec)

    assert {:continue, completed, [{:emit, settled}]} =
             Loop.dispatch(
               spec,
               Event.durable(:model_completed, %{message: "done", tool_calls: []}),
               initial
             )

    assert {{:stop, "done"}, _, []} = Loop.dispatch(spec, settled, completed)
  end
end
