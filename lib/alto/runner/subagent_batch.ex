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
        cond do
          state.pending != [] and map_size(state.active) < concurrency ->
            [spec | pending] = state.pending
            next = start_child(%{state | pending: pending}, spec, start, runner)
            drive(next, concurrency, start, check, runner)

          state.pending == [] and map_size(state.active) == 0 ->
            {:ok, state}

          true ->
            drive(collect(state, 50), concurrency, start, check, runner)
        end

      status ->
        {status, stop(state, status, runner)}
    end
  end

  defp start_child(state, spec, start, runner) do
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
    Enum.each(state.active, fn {_ref, {_id, handle}} -> runner.cancel(handle, status) end)
    skipped = Map.new(state.pending, &{&1.id, {:error, {:not_started, status}}})
    state = %{state | pending: [], completed: Map.merge(state.completed, skipped)}

    # One grace period for the entire batch, not one timeout per child.
    drain(state, System.monotonic_time(:millisecond) + 5_000, runner)
  end

  defp drain(state, deadline, runner) do
    cond do
      map_size(state.active) == 0 ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        Enum.reduce(state.active, %{state | active: %{}}, fn {_ref, {id, handle}}, acc ->
          complete(acc, id, runner.terminate(handle, :cancel_timeout))
        end)

      true ->
        drain(
          collect(state, max(deadline - System.monotonic_time(:millisecond), 0)),
          deadline,
          runner
        )
    end
  end
end
