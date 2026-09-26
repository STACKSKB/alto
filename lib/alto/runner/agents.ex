defmodule Alto.Runner.Agents do
  @moduledoc "In-memory child scheduling for nonblocking start and interruptible joins."
  use GenServer
  alias Alto.Runner
  alias Alto.Runner.Execution.Children

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
  def submit(pid, specs, run), do: GenServer.call(pid, {:submit, specs, run}, :infinity)
  def snapshot(pid, ids), do: GenServer.call(pid, {:snapshot, ids}, :infinity)
  def collect(pid), do: GenServer.call(pid, :collect, :infinity)
  def close(pid), do: GenServer.call(pid, :close, :infinity)

  # A waiting child relinquishes its parent's concurrency slot. It must acquire
  # a slot again before it returns to model/tool execution.
  def park(nil), do: :ok
  def park({pid, id}), do: GenServer.call(pid, {:park, id}, :infinity)
  def resume(nil), do: :ok
  def resume({pid, id}), do: GenServer.call(pid, {:resume, id}, :infinity)

  @impl true
  def init(owner), do: {:ok, %{owner: Process.monitor(owner), entries: %{}, order: [], limit: 1}}

  @impl true
  def handle_call({:submit, specs, run}, _from, state) do
    cond do
      map_size(state.entries) + length(specs) > 256 ->
        {:reply, {:error, :agent_capacity}, state}

      true ->
        entries =
          Map.new(specs, fn spec ->
            {spec.messaging.id,
             %{
               spec: spec,
               run:
                 run
                 |> Map.drop([:messages_rev, :events_rev, :loop_state])
                 |> Map.put(:execution_owner, self()),
               starter: nil,
               handle: nil,
               ref: nil,
               status: :pending,
               summary: nil,
               collected: false
             }}
          end)

        ids = Enum.map(specs, & &1.messaging.id)
        send(self(), :dispatch)

        next = %{
          state
          | entries: Map.merge(state.entries, entries),
            order: state.order ++ ids,
            limit: run.child_limits.max_concurrency
        }

        {:reply, {:ok, Enum.map(ids, &public(&1, next.entries[&1]))}, next}
    end
  end

  def handle_call({:snapshot, ids}, _from, state) do
    if Enum.all?(ids, &Map.has_key?(state.entries, &1)),
      do: {:reply, {:ok, Enum.map(ids, &public(&1, state.entries[&1]))}, state},
      else: {:reply, {:error, :unknown_agent}, state}
  end

  def handle_call(:collect, _from, state) do
    {summaries, state} = collect_summaries(state)
    {:reply, summaries, state}
  end

  def handle_call({:park, id}, _from, state) do
    state = update_status(state, id, :waiting)
    send(self(), :dispatch)
    {:reply, :ok, state}
  end

  def handle_call({:resume, id}, _from, state) do
    case state.entries[id] do
      %{status: :running} ->
        {:reply, :ok, state}

      %{status: status} when status in [:waiting, :resuming] ->
        if active(state) < state.limit do
          {:reply, :ok, update_status(state, id, :running)}
        else
          {:reply, :wait, update_status(state, id, :resuming)}
        end

      _ ->
        {:reply, {:error, :agent_closed}, state}
    end
  end

  def handle_call(:close, _from, state) do
    state = stop_children(state)
    {summaries, state} = collect_summaries(state)
    {:reply, summaries, state}
  end

  @impl true
  def handle_info(:dispatch, state), do: {:noreply, dispatch(state)}

  def handle_info({ref, outcome}, state) when is_reference(ref) do
    case Enum.find(state.entries, fn {_, entry} -> entry.starter && entry.starter.ref == ref end) do
      {id, entry} ->
        Process.demonitor(ref, [:flush])
        next = put_in(state.entries[id].starter, nil)

        next =
          case outcome do
            {:ok, handle} ->
              case Runner.subscribe(handle) do
                {:ok, subscription} ->
                  put_in(next.entries[id], %{
                    entry
                    | starter: nil,
                      handle: handle,
                      ref: subscription,
                      run: nil,
                      status: if(entry.status == :starting, do: :running, else: entry.status)
                  })

                {:error, reason} ->
                  failed(next, id, Runner.terminate(handle, {:subscription_failed, reason}))
              end

            {:error, reason} ->
              failed(next, id, {:error, reason})
          end

        {:noreply, dispatch(next)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:alto_runner_result, ref, outcome}, state) do
    case Enum.find(state.entries, fn {_, entry} -> entry.ref == ref end) do
      {id, entry} ->
        summary = Children.child_summary(entry.spec.id, outcome)
        next = put_in(state.entries[id], %{entry | status: :completed, summary: summary})
        {:noreply, dispatch(next)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state),
    do: {:stop, :normal, stop_children(state)}

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    case Enum.find(state.entries, fn {_, entry} -> entry.starter && entry.starter.ref == ref end) do
      {id, _} ->
        {:noreply,
         dispatch(
           failed(state, id, {:error, {:run_process_failed, {:child_start_failed, reason}}})
         )}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp dispatch(state) do
    next = Enum.find(state.order, &(state.entries[&1].status in [:pending, :resuming]))

    if next && active(state) < state.limit do
      entry = state.entries[next]

      if entry.status == :resuming do
        dispatch(update_status(state, next, :running))
      else
        spec = Map.put(entry.spec, :agent_scheduler, {self(), next})

        starter =
          Alto.Runner.Execution.Call.start(fn -> Children.start_subagent(spec, entry.run) end)

        entry = %{entry | starter: starter, status: :starting}
        dispatch(put_in(state.entries[next], entry))
      end
    else
      state
    end
  end

  defp failed(state, id, outcome) do
    entry = state.entries[id]
    Alto.Messaging.close(entry.spec.messaging)

    put_in(state.entries[id], %{
      entry
      | status: :completed,
        starter: nil,
        run: nil,
        summary: Children.child_summary(entry.spec.id, outcome)
    })
  end

  defp active(state),
    do: Enum.count(state.entries, fn {_, e} -> e.status in [:starting, :running] end)

  defp update_status(state, id, status),
    do: put_in(state.entries[id].status, status)

  defp public(id, entry) do
    base = %{agent_id: id, id: entry.spec.id, status: entry.status}

    if entry.summary,
      do: Map.put(base, :result, Children.public_child_summary(entry.summary)),
      else: base
  end

  defp collect_summaries(state) do
    Enum.reduce(state.order, {[], state}, fn id, {summaries, acc} ->
      case acc.entries[id] do
        %{summary: summary, collected: false} when not is_nil(summary) ->
          {[summary | summaries], put_in(acc.entries[id].collected, true)}

        _ ->
          {summaries, acc}
      end
    end)
  end

  defp stop_children(state) do
    Enum.each(state.entries, fn {_, entry} ->
      if entry.handle && entry.status != :completed,
        do: Runner.cancel(entry.handle, :parent_finished)
    end)

    deadline = System.monotonic_time(:millisecond) + 1_000

    Enum.reduce(state.order, state, fn id, acc ->
      entry = acc.entries[id]

      cond do
        entry.status == :completed ->
          acc

        entry.starter != nil ->
          case Task.shutdown(entry.starter, :brutal_kill) do
            {:ok, {:ok, handle}} ->
              Runner.cancel(handle, :parent_finished)
              failed(acc, id, Runner.terminate(handle, :parent_finished))

            _ ->
              failed(acc, id, {:error, {:run_process_failed, :child_start_interrupted}})
          end

        entry.handle == nil ->
          failed(acc, id, {:error, {:not_started, :parent_finished}})

        true ->
          outcome =
            case Runner.await(
                   entry.handle,
                   max(deadline - System.monotonic_time(:millisecond), 0)
                 ) do
              {:error, :await_timeout} -> Runner.terminate(entry.handle, :parent_finished)
              outcome -> outcome
            end

          failed(acc, id, outcome)
      end
    end)
  end
end
