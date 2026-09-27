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
    use Alto.Tool, name: :echo, execution_mode: :parallel, approval: :never
    def schema(_opts), do: %{parameters: %{type: "object", properties: %{}}}
    def run(_args, _ctx, _opts), do: {:ok, %{echo: true}}
  end

  defmodule StrictLoop do
    @behaviour Alto.Loop

    alias Alto.Event

    @impl true
    def init(_task, _spec), do: {:continue, %{step: 1}, [{:request_model, %{}}]}

    @impl true
    def handle_event(
          %Event{type: :model_completed, data: %{tool_calls: [call]}},
          %{step: 1},
          _spec
        ) do
      {:continue, %{step: 2}, [{:run_tool, call}]}
    end

    def handle_event(%Event{type: :tool_completed}, %{step: 2}, _spec),
      do: {:continue, %{step: 3}, [{:request_model, %{}}]}

    def handle_event(%Event{type: :model_completed, data: %{tool_calls: []}}, state, _spec),
      do: {{:stop, :done}, state, []}
  end

  test "strict provider correlation preserves call ids while minting host operation ids" do
    assert %Alto.Runner.Result{status: :ok} =
             result =
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
    {:ok, _} = Queue.request(queue, {:admit, "src:unknown", %{}, []})
    :ok = OperationLog.request(ledger, {:intent, "src:unknown", "tool", "src:unknown", nil})
    :ok = OperationLog.request(ledger, {:attempt, "src:unknown", "attempt-1"})
    :ok = OperationLog.request(ledger, {:outcome, "src:unknown", "attempt-1", :unknown, %{}})

    assert {:ok, %{items: [%{status: :unknown}]}} = Ops.list(queue, ledger, filter: :unknown)

    {:ok, consumer} =
      Consumer.start_link(
        queue: queue,
        ledger: ledger,
        handler: fn _, _ -> {:outcome, :completed, %{}} end,
        name: nil,
        autostart: false
      )

    assert {:handled, [:parked_unknown]} = Consumer.poll(consumer)
  end
end
