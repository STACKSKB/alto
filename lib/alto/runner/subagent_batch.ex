defmodule Alto.Runner.SubagentBatch do
  @moduledoc "Runs bounded child handles through a runner lifecycle contract."

  # Handles remain owned by the parent host. Each child also monitors that host,
  # so an unexpected parent exit cancels children without relying on this loop.
  @doc "Run children with `start` and a runner module implementing subscribe/cancel/terminate."
  def run(specs, concurrency, start, check, opts \\ []) do
    runner = Keyword.get(opts, :runner, Alto.Runner)
    state = %{pending: specs, active: %{}, completed: %{}}
    {status, state} = drive(state, concurrency, start, check, runner)
    outcomes = Enum.map(specs, &{&1.id, Map.fetch!(state.completed, &1.id)})
    {status, outcomes}
  end

  defp drive(state, concurrency, start, check, runner) do
    case check.() do
      :continue ->
        case admit(state, concurrency, start, check, runner) do
          {:ok, state} ->
            if state.pending == [] and map_size(state.active) == 0 do
              {:ok, state}
            else
              drive(collect(state, 50), concurrency, start, check, runner)
            end

          {status, state} ->
            {status, stop(state, status, runner)}
        end

      status ->
        {status, stop(state, status, runner)}
    end
  end

  defp admit(%{pending: []} = state, _concurrency, _start, _check, _runner), do: {:ok, state}

  defp admit(state, concurrency, start, check, runner) do
    if map_size(state.active) >= concurrency do
      {:ok, state}
    else
      case check.() do
        :continue ->
          [spec | pending] = state.pending
          state = %{state | pending: pending}

          state =
            case start.(spec) do
              {:ok, handle} ->
                case runner.subscribe(handle, self()) do
                  {:ok, ref} ->
                    %{state | active: Map.put(state.active, ref, {spec.id, handle})}

                  {:error, reason} ->
                    runner.terminate(handle, :subscription_failed)
                    complete(state, spec.id, {:error, {:subscription_failed, reason}})
                end

              {:error, reason} ->
                complete(state, spec.id, {:error, reason})
            end

          admit(state, concurrency, start, check, runner)

        status ->
          {status, state}
      end
    end
  end

  # Only consume completions owned by this batch. The timeout checks the
  # parent's cancellation/deadline callback; completion itself is event-driven.
  defp collect(state, timeout) do
    active = state.active

    receive do
      {:alto_runner_result, ref, outcome} when is_map_key(active, ref) ->
        {{id, _handle}, active} = Map.pop(active, ref)
        complete(%{state | active: active}, id, outcome)
    after
      timeout -> state
    end
  end

  defp complete(state, id, outcome),
    do: %{state | completed: Map.put(state.completed, id, outcome)}

  defp stop(state, status, runner) do
    Enum.each(state.active, fn {_ref, {_id, handle}} -> cancel(runner, handle, status) end)

    state =
      Enum.reduce(state.pending, %{state | pending: []}, fn spec, acc ->
        complete(acc, spec.id, {:error, {:not_started, status}})
      end)

    # One grace period for the entire batch, not one timeout per child.
    drain(state, System.monotonic_time(:millisecond) + 5_000, runner)
  end

  defp drain(state, deadline, runner) do
    cond do
      map_size(state.active) == 0 ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        Enum.reduce(state.active, %{state | active: %{}}, fn {_ref, {id, handle}}, acc ->
          complete(acc, id, terminate(runner, handle))
        end)

      true ->
        drain(
          collect(state, max(deadline - System.monotonic_time(:millisecond), 0)),
          deadline,
          runner
        )
    end
  end

  defp cancel(runner, handle, reason), do: runner.cancel(handle, reason)
  defp terminate(runner, handle), do: runner.terminate(handle, :cancel_timeout)
end
