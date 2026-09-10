defmodule Alto.Runner.SubagentBatch do
  @moduledoc false
  alias Alto.Runner.Serial

  # Handles remain owned by the parent host. Each child also monitors that host,
  # so an unexpected parent exit cancels children without relying on this loop.
  def run(specs, concurrency, start, check) do
    state = %{pending: specs, active: [], completed: %{}}
    {status, state} = drive(state, concurrency, start, check)
    outcomes = Enum.map(specs, &{&1.id, Map.fetch!(state.completed, &1.id)})
    {status, outcomes}
  end

  defp drive(state, concurrency, start, check) do
    case check.() do
      :continue ->
        case admit(state, concurrency, start, check) do
          {:ok, state} ->
            state = collect(state)

            if state.pending == [] and state.active == [] do
              {:ok, state}
            else
              Process.sleep(10)
              drive(state, concurrency, start, check)
            end

          {status, state} ->
            {status, stop(state, status)}
        end

      status ->
        {status, stop(state, status)}
    end
  end

  defp admit(%{pending: []} = state, _concurrency, _start, _check), do: {:ok, state}

  defp admit(state, concurrency, start, check) do
    if length(state.active) >= concurrency do
      {:ok, state}
    else
      case check.() do
        :continue ->
          [spec | pending] = state.pending
          state = %{state | pending: pending}

          state =
            case start.(spec) do
              {:ok, handle} -> %{state | active: [{spec.id, handle} | state.active]}
              {:error, reason} -> complete(state, spec.id, {:error, reason})
            end

          admit(state, concurrency, start, check)

        status ->
          {status, state}
      end
    end
  end

  defp collect(state) do
    Enum.reduce(state.active, %{state | active: []}, fn {id, handle}, acc ->
      case Serial.await(handle, 0) do
        {:error, :await_timeout} -> %{acc | active: [{id, handle} | acc.active]}
        outcome -> complete(acc, id, outcome)
      end
    end)
  end

  defp complete(state, id, outcome),
    do: %{state | completed: Map.put(state.completed, id, outcome)}

  defp stop(state, status) do
    Enum.each(state.active, fn {_id, handle} -> Serial.cancel(handle, status) end)

    state =
      Enum.reduce(state.pending, %{state | pending: []}, fn spec, acc ->
        complete(acc, spec.id, {:error, {:not_started, status}})
      end)

    # One grace period for the entire batch, not one timeout per child.
    drain(state, System.monotonic_time(:millisecond) + 5_000)
  end

  defp drain(state, deadline) do
    state = collect(state)

    cond do
      state.active == [] ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        Enum.reduce(state.active, %{state | active: []}, fn {id, handle}, acc ->
          outcome =
            case Task.shutdown(handle.task, :brutal_kill) do
              {:ok, result} -> result
              _ -> {:error, {:run_process_failed, :cancel_timeout}}
            end

          complete(acc, id, outcome)
        end)

      true ->
        Process.sleep(10)
        drain(state, deadline)
    end
  end
end
