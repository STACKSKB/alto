defmodule Alto.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.Loop
  alias Alto.Runtime

  test "middleware enters in declaration order and unwinds in reverse" do
    owner = self()

    trace = fn label ->
      fn event, _context, next ->
        send(owner, {:middleware, label, :before})
        transition = next.(event)
        send(owner, {:middleware, label, :after})
        transition
      end
    end

    spec = Alto.default_loop(middleware: Enum.map([:first, :second], trace))

    {:continue, initial, _} = Runtime.init(spec, "answer")

    Runtime.dispatch(
      spec,
      Event.durable(:model_completed, %{message: "done", tool_calls: []}),
      initial
    )

    assert_receive {:middleware, :first, :before}
    assert_receive {:middleware, :second, :before}
    assert_receive {:middleware, :second, :after}
    assert_receive {:middleware, :first, :after}
  end

  test "after-step effects run before the default loop continuation" do
    commit_hook = fn event, context ->
      assert event.type == :step_settled
      assert context.workspace == "/repo"

      [
        {:invoke_tool,
         %{
           id: "commit-hook",
           name: "git_commit",
           arguments: %{if_dirty: true}
         }}
      ]
    end

    spec =
      Alto.default_loop()
      |> Loop.after_event(:step_settled, commit_hook)

    {:continue, initial, _} = Runtime.init(spec, "change a file")

    {:continue, tools, _} =
      Runtime.dispatch(
        spec,
        Event.durable(:model_completed, %{
          message: nil,
          tool_calls: [%{id: "edit", name: :edit, arguments: %{}}]
        }),
        initial
      )

    {:continue, completed, [{:emit, settled}]} =
      Runtime.dispatch(
        spec,
        Event.durable(:tool_completed, %{call_id: "edit", result: :ok}),
        tools
      )

    {:continue, _, effects} =
      Runtime.dispatch(spec, settled, completed, %{workspace: "/repo"})

    assert [
             {:invoke_tool, %{name: "git_commit"}},
             {:request_model, _}
           ] = effects
  end
end
