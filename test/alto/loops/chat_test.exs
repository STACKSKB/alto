defmodule Alto.Loops.ChatTest do
  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.Loop

  test "rejects tool calls instead of silently ignoring them" do
    spec = Alto.chat_loop(driver_options: [tool_execution: :serial])
    {:continue, initial, _} = spec.driver.init("hello", spec)

    transition =
      Loop.dispatch(
        spec,
        Event.durable(:model_completed, %{
          message: nil,
          tool_calls: [%{id: "call-1", name: "read_file", arguments_json: "{}"}]
        }),
        initial
      )

    assert {{:error, {:tools_not_supported, ["call-1"]}}, _, []} = transition
  end
end
