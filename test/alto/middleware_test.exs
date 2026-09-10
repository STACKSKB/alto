defmodule Alto.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Loop
  alias Alto.Runtime

  defmodule Trace do
    @behaviour Alto.Middleware

    @impl true
    def call(event, _context, next, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      label = Keyword.fetch!(opts, :label)
      send(test_pid, {:middleware, label, :before})
      transition = next.(event)
      send(test_pid, {:middleware, label, :after})
      transition
    end
  end

  test "middleware enters in declaration order and unwinds in reverse" do
    spec =
      Alto.default_loop(
        middleware: [
          {Trace, test_pid: self(), label: :first},
          {Trace, test_pid: self(), label: :second}
        ]
      )

    initial = Runtime.init(spec, "answer")

    Runtime.dispatch(
      spec,
      Event.durable(:model_completed, %{message: "done", tool_calls: []}),
      initial.state
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
        Effect.invoke_tool(%{
          id: "commit-hook",
          name: "git_commit",
          arguments: %{if_dirty: true}
        })
      ]
    end

    spec =
      Alto.default_loop()
      |> Loop.after_event(:step_settled, commit_hook)

    initial = Runtime.init(spec, "change a file")

    tools =
      Runtime.dispatch(
        spec,
        Event.durable(:model_completed, %{
          message: nil,
          tool_calls: [%{id: "edit", name: :edit, arguments: %{}}]
        }),
        initial.state
      )

    completed =
      Runtime.dispatch(
        spec,
        Event.durable(:tool_completed, %{call_id: "edit", result: :ok}),
        tools.state
      )

    assert [%Effect{data: %{event: settled}}] = completed.effects

    continuation =
      Runtime.dispatch(spec, settled, completed.state, %{workspace: "/repo"})

    assert [
             %Effect{kind: :invoke_tool, data: %{name: "git_commit"}},
             %Effect{kind: :request_model}
           ] = continuation.effects
  end
end
