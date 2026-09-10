defmodule Alto.Runner.Serial do
  @moduledoc """
  Sequential scheduler for Alto's shared execution components.

  Runs each requested effect immediately after the previous transition. Use
  `Alto.Runner.Stepped` for an independently controlled stepping scheduler.
  Both hosts share the same tool, approval, budget and persistence components.
  """
  @behaviour Alto.Runner
  alias Alto.Runner.{Execution, Result, TaskHost}
  @type run_result :: {:ok, Result.t()} | {:error, term(), Result.t()}

  @impl true
  def run(task, opts \\ []),
    do: Execution.run(task, Keyword.put_new(opts, :runner, __MODULE__), &drive/2)

  defp drive(frame, context) do
    case Execution.step(frame, context) do
      {:continue, next, context} -> drive(next, context)
      {:done, outcome} -> outcome
    end
  end

  @impl true
  def start(task, opts \\ []) do
    TaskHost.start(fn ref -> run(task, Keyword.put(opts, :cancel_ref, ref)) end, opts)
  end

  @impl true
  defdelegate await(handle, timeout \\ :infinity), to: TaskHost
  @impl true
  defdelegate cancel(handle, reason \\ :user), to: TaskHost
  @impl true
  defdelegate terminate(handle, reason \\ :cancel_timeout), to: TaskHost
  @impl true
  defdelegate subscribe(handle, pid \\ self()), to: TaskHost
end
