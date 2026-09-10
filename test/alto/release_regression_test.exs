defmodule Alto.ReleaseRegressionTest do
  use ExUnit.Case, async: false

  alias Alto.{Consumer, OperationLog, Ops, Queue}

  defmodule StrictProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, _opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        calls =
          for message <- request.messages,
              call <- message["tool_calls"] || [],
              do: call["id"]

        results =
          for message <- request.messages, message["role"] == "tool", do: message["tool_call_id"]

        if Enum.sort(calls) != Enum.sort(results), do: raise("tool correlation mismatch")
        {:ok, %{message: "settled", tool_calls: []}}
      else
        {:ok, %{message: nil, tool_calls: [%{id: "c1", name: "echo", arguments_json: "{}"}]}}
      end
    end
  end

  defmodule EchoTool do
    @behaviour Alto.Tool
    def name, do: :echo
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :parallel
    def approval, do: :never
    def run(_args, _ctx), do: {:ok, %{echo: true}}
  end

  defmodule StrictLoop do
    @behaviour Alto.Loop

    alias Alto.{Effect, Event, Transition}

    @impl true
    def init(_task, _spec), do: Transition.continue(%{step: 1}, [Effect.request_model(%{})])

    @impl true
    def handle_event(
          %Event{type: :model_completed, data: %{tool_calls: [call]}},
          %{step: 1},
          _spec
        ) do
      Transition.continue(%{step: 2}, [Effect.run_tool(call)])
    end

    def handle_event(%Event{type: :tool_completed}, %{step: 2}, _spec),
      do: Transition.continue(%{step: 3}, [Effect.request_model(%{})])

    def handle_event(%Event{type: :model_completed, data: %{tool_calls: []}}, state, _spec),
      do: Transition.stop(state, :done)
  end

  test "strict provider correlation preserves call ids while minting host operation ids" do
    assert {:ok, result} =
             Alto.run(:go,
               loop: Alto.loop(StrictLoop),
               tools: [EchoTool],
               model_tools: ["echo"],
               provider: StrictProvider
             )

    assert result.output == :done

    completed = Enum.find(result.events, &(&1.type == :tool_completed))
    assert completed.data.call_id == "c1"
    assert completed.data.operation_id != "c1"
  end

  test "unknown decisions remain visible and are not treated as completed" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto-release-regression-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, queue} = Queue.start_link(id: "q", dir: Path.join(dir, "q"), name: nil)
    {:ok, ledger} = OperationLog.start_link(id: "l", dir: Path.join(dir, "l"), name: nil)
    {:ok, _} = Queue.admit(queue, "src:unknown", %{})
    :ok = OperationLog.record_intent(ledger, "src:unknown", "tool", "src:unknown")
    :ok = OperationLog.record_attempt(ledger, "src:unknown", "attempt-1")
    :ok = OperationLog.record_outcome(ledger, "src:unknown", "attempt-1", :unknown)

    assert {:ok, %{items: [%{status: :unknown}]}} = Ops.list(queue, ledger, filter: :unknown)

    {:ok, consumer} =
      Consumer.start_link(
        queue: queue,
        ledger: ledger,
        handler: fn _, _ -> :done end,
        name: nil,
        autostart: false
      )

    assert {:handled, [:parked_unknown]} = Consumer.poll(consumer)
  end
end
