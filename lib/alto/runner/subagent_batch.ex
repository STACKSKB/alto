defmodule Alto.Runner.SubagentBatch do
  @moduledoc "Runs bounded child handles through a runner lifecycle contract."

  # Handles remain owned by the parent host. Each child also monitors that host,
  # so an unexpected parent exit cancels children without relying on this loop.
  @doc "Run children with `start` and a runner module implementing await/cancel/terminate."
  def run(specs, concurrency, start, check, opts \\ []) do
    runner = Keyword.get(opts, :runner, Alto.Runner)
    state = %{pending: specs, active: [], completed: %{}}
    {status, state} = drive(state, concurrency, start, check, runner)
    outcomes = Enum.map(specs, &{&1.id, Map.fetch!(state.completed, &1.id)})
    {status, outcomes}
  end

  defp drive(state, concurrency, start, check, runner) do
    case check.() do
      :continue ->
        case admit(state, concurrency, start, check) do
          {:ok, state} ->
            state = collect(state, runner)

            if state.pending == [] and state.active == [] do
              {:ok, state}
            else
              Process.sleep(10)
              drive(state, concurrency, start, check, runner)
            end

          {status, state} ->
            {status, stop(state, status, runner)}
        end

      status ->
        {status, stop(state, status, runner)}
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

  defp collect(state, runner) do
    Enum.reduce(state.active, %{state | active: []}, fn {id, handle}, acc ->
      case await(runner, handle) do
        {:error, :await_timeout} -> %{acc | active: [{id, handle} | acc.active]}
        outcome -> complete(acc, id, outcome)
      end
    end)
  end

  defp complete(state, id, outcome),
    do: %{state | completed: Map.put(state.completed, id, outcome)}

  defp stop(state, status, runner) do
    Enum.each(state.active, fn {_id, handle} -> cancel(runner, handle, status) end)

    state =
      Enum.reduce(state.pending, %{state | pending: []}, fn spec, acc ->
        complete(acc, spec.id, {:error, {:not_started, status}})
      end)

    # One grace period for the entire batch, not one timeout per child.
    drain(state, System.monotonic_time(:millisecond) + 5_000, runner)
  end

  defp drain(state, deadline, runner) do
    state = collect(state, runner)

    cond do
      state.active == [] ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        Enum.reduce(state.active, %{state | active: []}, fn {id, handle}, acc ->
          complete(acc, id, terminate(runner, handle))
        end)

      true ->
        Process.sleep(10)
        drain(state, deadline, runner)
    end
  end

  defp await(runner, handle), do: runner.await(handle, 0)
  defp cancel(runner, handle, reason), do: runner.cancel(handle, reason)
  defp terminate(runner, handle), do: runner.terminate(handle, :cancel_timeout)
end
