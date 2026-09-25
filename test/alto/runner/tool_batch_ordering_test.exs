defmodule Alto.Runner.ToolBatchOrderingTest do
  use ExUnit.Case, async: true

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Transition

  defmodule Read do
    use Alto.Tool, name: :ordered_read, execution_mode: :parallel, approval: :never

    def schema(_), do: %{parameters: %{type: "object", properties: %{}}}

    def prepare(args, _context, opts) do
      send(opts[:owner], {:prepared, args["id"]})
      {:ok, args, %{}}
    end

    def run_prepared(args, _context, opts) do
      send(opts[:owner], {:read_started, args["id"], self()})

      if args["block"] do
        receive do
          :finish -> :ok
        end
      end

      {:ok, args["id"]}
    end
  end

  defmodule Probe do
    use Alto.Tool, name: :batch_probe, execution_mode: :exclusive, approval: :never

    def schema(_), do: %{parameters: %{type: "object", properties: %{}}}

    def run(%{"source" => source}, _context, opts) do
      send(opts[:owner], {:probe_started, source})
      {:ok, source}
    end
  end

  defmodule Loop do
    @behaviour Alto.Loop

    def init(_task, _spec) do
      calls = [
        %{id: "a", name: "ordered_read", arguments_json: JSON.encode!(%{id: "a", block: true})},
        %{id: "b", name: "ordered_read", arguments_json: JSON.encode!(%{id: "b"})}
      ]

      Transition.continue(%{reads: 0, probes: 0}, [Effect.run_tools(calls, 2)])
    end

    def handle_event(%Event{type: :tool_completed, data: %{name: "ordered_read"}}, state, _) do
      Transition.continue(%{state | reads: state.reads + 1})
    end

    def handle_event(%Event{type: :tool_completed, data: %{name: "batch_probe"}}, state, _) do
      next = %{state | probes: state.probes + 1}
      if next.probes == 2, do: Transition.stop(next, :done), else: Transition.continue(next)
    end
  end

  defmodule CompletionEffect do
    @behaviour Alto.Middleware

    def call(%Event{} = event, _context, next, opts) do
      owner = Keyword.fetch!(opts, :owner)
      send(owner, {:middleware, event.type, event.data[:call_id], event.data[:name]})
      transition = next.(event)

      if event.type == :tool_completed and event.data.name == "ordered_read" do
        Transition.prepend_effects(transition, [
          Effect.invoke_tool(%{
            id: "probe-#{event.data.call_id}",
            name: "batch_probe",
            arguments: %{"source" => event.data.call_id}
          })
        ])
      else
        transition
      end
    end
  end

  test "middleware sees source order and its effects wait for the whole group" do
    loop = Alto.loop(Loop, middleware: [{CompletionEffect, owner: self()}])

    {:ok, handle} =
      Alto.start(:ignored,
        loop: loop,
        tools: [{Read, owner: self()}, {Probe, owner: self()}]
      )

    assert_receive {:prepared, "a"}
    assert_receive {:prepared, "b"}
    refute_receive {:prepared, _}, 20
    assert_receive {:read_started, "a", first}
    assert_receive {:read_started, "b", _second}

    # The second worker has returned, but completion dispatch and middleware
    # effects wait until the blocking sibling settles.
    refute_receive {:middleware, :tool_completed, _, _}, 20
    refute_receive {:probe_started, _}, 20
    send(first, :finish)

    assert_receive {:middleware, :tool_completed, "a", "ordered_read"}
    assert_receive {:middleware, :tool_completed, "b", "ordered_read"}
    assert_receive {:probe_started, "a"}
    assert_receive {:middleware, :tool_completed, "probe-a", "batch_probe"}
    assert_receive {:probe_started, "b"}
    assert_receive {:middleware, :tool_completed, "probe-b", "batch_probe"}
    assert {:ok, %{output: :done}} = Alto.await(handle)
  end
end
