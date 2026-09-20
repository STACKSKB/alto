defmodule Alto.Runner.ToolBatchFaultTest do
  use ExUnit.Case, async: true

  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Tool.Capabilities
  alias Alto.Runner.ToolBatch

  defmodule ControlledTool do
    @behaviour Alto.Tool

    def name(_), do: :controlled_batch_tool
    def schema(_), do: %{parameters: %{type: "object", properties: %{}}}
    def execution_mode(_), do: :parallel
    def approval(_), do: :never

    def run(%{id: id}, _context, opts) do
      owner = Keyword.fetch!(opts, :owner)
      send(owner, {:batch_worker, id, self()})

      receive do
        :finish -> {:ok, id}
      end
    end
  end

  test "cancellation preserves a result already delivered to the coordinator mailbox" do
    cancel_ref = make_ref()
    {:ok, budget} = Budget.new(run_timeout: 5_000)
    caps = capabilities(budget, cancel_ref)
    tool = tool(self())
    parent = self()

    coordinator =
      spawn(fn ->
        result = ToolBatch.run([{tool, %{id: :finished}}, {tool, %{id: :pending}}], caps)
        send(parent, {:batch_result, result})
      end)

    assert_receive {:batch_worker, :finished, finished}
    assert_receive {:batch_worker, :pending, pending}

    # Hold the coordinator so the first Task result is definitely queued
    # before cancellation. Cancellation is a selective receive and therefore
    # can otherwise skip over that earlier result message.
    :erlang.suspend_process(coordinator)
    finished_ref = Process.monitor(finished)
    send(finished, :finish)
    assert_receive {:DOWN, ^finished_ref, :process, ^finished, :normal}
    send(coordinator, {:alto_cancel, cancel_ref, :operator_stop})
    :erlang.resume_process(coordinator)

    assert_receive {:batch_result,
                    {:cancelled, :operator_stop, [{:ok, {:ok, :finished}}, {:error, :cancelled}]}}

    pending_ref = Process.monitor(pending)
    assert_receive {:DOWN, ^pending_ref, :process, ^pending, _}
  end

  test "hard owner death terminates a worker guarded before participant dispatch" do
    {:ok, budget} = Budget.new(run_timeout: 5_000)
    caps = capabilities(budget, nil)
    tool = tool(self())

    coordinator =
      spawn(fn ->
        ToolBatch.run([{tool, %{id: :blocked}}], caps)
      end)

    assert_receive {:batch_worker, :blocked, worker}
    worker_ref = Process.monitor(worker)
    Process.exit(coordinator, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
  end

  defp capabilities(budget, cancel_ref) do
    %Capabilities{
      tools: %{},
      approval: {Alto.Approvals.DenyAll, []},
      context: nil,
      budget: budget,
      cancel_ref: cancel_ref,
      tool_timeout: 5_000
    }
  end

  defp tool(owner), do: %{module: ControlledTool, opts: [owner: owner]}
end
