defmodule Alto.Loops.ChatTest do
  use ExUnit.Case, async: true

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Runtime

  test "is swappable through the same loop specification and runtime" do
    spec = Alto.chat_loop()
    initial = Runtime.init(spec, "hello")

    assert [%Effect{kind: :request_model, data: %{task: "hello"}}] = initial.effects

    completed =
      Runtime.dispatch(
        spec,
        Event.durable(:model_completed, %{message: "hi", tool_calls: []}),
        initial.state
      )

    assert completed.status == :stop
    assert completed.result == "hi"
  end

  test "rejects tool calls instead of silently ignoring them" do
    spec = Alto.chat_loop()
    initial = Runtime.init(spec, "hello")

    transition =
      Runtime.dispatch(
        spec,
        Event.durable(:model_completed, %{
          message: nil,
          tool_calls: [%{id: "call-1", name: "read_file", arguments_json: "{}"}]
        }),
        initial.state
      )

    assert transition.status == :error
    assert transition.error == {:tools_not_supported, ["call-1"]}
  end
end
