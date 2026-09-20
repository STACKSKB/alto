defmodule Alto.Runner.ToolBatch do
  @moduledoc """
  Bounded concurrent invocation without shared transcript or loop mutation.

  The caller admits at most 32 jobs and retains ownership of accounting.
  Results are bounded before they leave workers and returned in source order.
  Worker guardians terminate work if the coordinator dies, including hard kills.
  """
  alias Alto.Runner.{Budget, Execution.Call, Execution.Support, Execution.Tool}

  def run(jobs, caps) when is_list(jobs) and length(jobs) <= 32 do
    owner = self()

    tasks =
      Enum.map(jobs, fn {tool, prepared} ->
        task =
          Task.Supervisor.async_nolink(Alto.TaskSupervisor, fn ->
            # Establish ownership before entering participant code. Doing
            # this from the coordinator after `async_nolink/2` would leave a
            # hard-death window with an unowned worker.
            Support.guard_owner(owner)

            tool
            |> Tool.invoke_tool(prepared, caps.context)
            |> bound_result(caps.max_tool_result_bytes)
          end)

        {task,
         System.monotonic_time(:millisecond) + Budget.timeout(caps.budget, caps.tool_timeout)}
      end)

    try do
      collect(tasks, caps, %{})
    after
      Enum.each(tasks, fn {task, _} -> Task.shutdown(task, :brutal_kill) end)
    end
  end

  defp collect(tasks, caps, results) do
    case {Call.cancellation(caps.cancel_ref), Budget.check(caps.budget)} do
      {{:cancelled, reason}, _} ->
        results = harvest(tasks, results)
        {:cancelled, reason, ordered(tasks, results, {:error, :cancelled})}

      {_, {:error, reason}} ->
        results = harvest(tasks, results)
        {:error, reason, ordered(tasks, results, {:error, reason})}

      {:continue, :ok} ->
        results =
          Enum.reduce(tasks, results, fn {task, deadline}, acc ->
            if Map.has_key?(acc, task.ref) do
              acc
            else
              result =
                case Task.yield(task, 0) do
                  {:ok, value} ->
                    {:ok, value}

                  {:exit, reason} ->
                    {:error, reason}

                  nil ->
                    if System.monotonic_time(:millisecond) >= deadline do
                      Task.shutdown(task, :brutal_kill)
                      {:error, :timeout}
                    end
                end

              if result, do: Map.put(acc, task.ref, result), else: acc
            end
          end)

        if map_size(results) == length(tasks) do
          {:ok, ordered(tasks, results, nil)}
        else
          receive do
          after
            5 -> :ok
          end

          collect(tasks, caps, results)
        end
    end
  end

  defp ordered(tasks, results, fallback),
    do: Enum.map(tasks, fn {task, _} -> Map.get(results, task.ref, fallback) end)

  # Match sequential execution: a successful participant value is the bounded
  # native result, rather than the surrounding outcome tuple.
  defp bound_result({:ok, value} = outcome, limit) do
    case Tool.check_native_result(value, limit) do
      :ok -> outcome
      {:error, reason} -> {:batch_oversize, reason}
    end
  end

  defp bound_result(outcome, limit) do
    case Tool.check_native_result(outcome, limit) do
      :ok -> outcome
      {:error, reason} -> {:batch_oversize, reason}
    end
  end

  # Cancellation is received selectively, so completed task messages can be
  # sitting earlier in the coordinator mailbox.  Preserve those decided
  # outcomes before assigning an unknown fallback to work still in flight.
  defp harvest(tasks, results) do
    Enum.reduce(tasks, results, fn {task, _deadline}, acc ->
      if Map.has_key?(acc, task.ref) do
        acc
      else
        case Task.yield(task, 0) do
          {:ok, value} -> Map.put(acc, task.ref, {:ok, value})
          {:exit, reason} -> Map.put(acc, task.ref, {:error, reason})
          nil -> acc
        end
      end
    end)
  end
end
