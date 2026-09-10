defmodule Alto.Runner.Execution.Support do
  @moduledoc false

  @doc "Run a participant under the task supervisor with a deadline and cancellation."
  def supervised_call(_fun, timeout, _cancel_ref) when timeout <= 0, do: {:error, :timeout}

  def supervised_call(fun, timeout, cancel_ref) when is_function(fun, 0) do
    task = Task.Supervisor.async_nolink(Alto.TaskSupervisor, fun)
    await(task, System.monotonic_time(:millisecond) + max(timeout, 0), cancel_ref)
  end

  defp await(task, deadline, cancel_ref) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, min(remaining, 50)) do
      {:ok, value} ->
        {:ok, value}

      {:exit, reason} ->
        {:error, reason}

      nil when remaining == 0 ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}

      nil ->
        case cancellation(cancel_ref) do
          {:cancelled, reason} ->
            Task.shutdown(task, :brutal_kill)
            {:cancelled, reason}

          :continue ->
            await(task, deadline, cancel_ref)
        end
    end
  end

  @doc "Read one cooperative cancellation message, if present."
  def cancellation(nil), do: :continue

  def cancellation(ref) do
    receive do
      {:alto_cancel, ^ref, reason} -> {:cancelled, reason}
    after
      0 -> :continue
    end
  end

  @doc "Safely notify a live event sink."
  def notify(nil, _event), do: :ok

  def notify(sink, event) when is_function(sink, 1) do
    sink.(event)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def notify(_, _), do: :ok
end
