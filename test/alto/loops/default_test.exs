defmodule Alto.Loops.DefaultTest do
  use ExUnit.Case, async: true

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Runtime

  test "starts by requesting a model response" do
    context = Alto.Context.window(max_tokens: 200_000, reserve_output: 16_000)
    spec = Alto.default_loop(context: context)

    transition = Runtime.init(spec, "fix the parser")

    assert transition.status == :continue
    assert transition.state.phase == :awaiting_model

    assert [
             %Effect{
               kind: :request_model,
               data: %{task: "fix the parser", step: 1, context: ^context}
             }
           ] = transition.effects
  end

  test "waits for all tools, settles the step, then requests the model again" do
    spec = Alto.default_loop()
    initial = Runtime.init(spec, "inspect the repository")

    model =
      Event.durable(:model_completed, %{
        message: %{role: :assistant},
        tool_calls: [
          %{id: "call-1", name: :rg, arguments: %{pattern: "TODO"}},
          %{id: "call-2", name: :git_diff, arguments: %{}}
        ]
      })

    tools = Runtime.dispatch(spec, model, initial.state)

    assert Enum.map(tools.effects, & &1.kind) == [:run_tool, :run_tool]

    first_result =
      Runtime.dispatch(
        spec,
        Event.durable(:tool_completed, %{call_id: "call-1", result: "matches"}),
        tools.state
      )

    assert first_result.effects == []

    second_result =
      Runtime.dispatch(
        spec,
        Event.durable(:tool_completed, %{call_id: "call-2", result: "diff"}),
        first_result.state
      )

    assert [%Effect{kind: :emit, data: %{event: %Event{type: :step_settled} = settled}}] =
             second_result.effects

    next_step = Runtime.dispatch(spec, settled, second_result.state)

    assert next_step.state.step == 2

    assert [%Effect{kind: :request_model, data: %{step: 2, observations: observations}}] =
             next_step.effects

    assert Enum.map(observations, & &1.data.call_id) == ["call-1", "call-2"]
  end

  test "a final model response stops only after the step-settled boundary" do
    spec = Alto.default_loop()
    initial = Runtime.init(spec, "answer briefly")

    completed =
      Runtime.dispatch(
        spec,
        Event.durable(:model_completed, %{message: "done", tool_calls: []}),
        initial.state
      )

    assert completed.status == :continue
    assert [%Effect{kind: :emit, data: %{event: settled}}] = completed.effects

    stopped = Runtime.dispatch(spec, settled, completed.state)

    assert stopped.status == :stop
    assert stopped.result == "done"
  end
end
