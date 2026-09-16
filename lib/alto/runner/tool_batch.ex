defmodule Alto.Runner.ToolBatch do
  @moduledoc """
  Bounded concurrent invocation without shared transcript or loop mutation.

  The caller admits at most 32 jobs and retains ownership of accounting.
  Results are bounded before they leave workers and returned in source order.
  Worker guardians terminate work if the coordinator dies, including hard kills.
  """
  alias Alto.Runner.{Budget, Execution.Call, Execution.Tool}

  def run(jobs, caps) when is_list(jobs) and length(jobs) <= 32 do
    owner = self()

    tasks =
      Enum.map(jobs, fn {tool, prepared} ->
        task =
          Task.Supervisor.async_nolink(Alto.TaskSupervisor, fn ->
            value = Tool.invoke_tool(tool, prepared, caps.context)

            case Tool.check_native_result(value, caps.max_tool_result_bytes) do
              :ok -> value
              {:error, reason} -> {:batch_oversize, reason}
            end
          end)

        spawn(fn -> guard(owner, task.pid) end)

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
        {:cancelled, reason, ordered(tasks, results, {:error, :cancelled})}

      {_, {:error, reason}} ->
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

  defp guard(owner, worker) do
    owner_ref = Process.monitor(owner)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^owner_ref, :process, _, _} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_ref, :process, _, _} -> :ok
    end
  end
end
