defmodule Alto.Runner.Agents do
  @moduledoc "Child scheduling for nonblocking start and interruptible joins."
  use GenServer
  alias Alto.Runner
  alias Alto.Runner.Execution.Children

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
  def submit(pid, specs, run), do: GenServer.call(pid, {:submit, specs, run}, :infinity)
  def snapshot(pid, ids), do: GenServer.call(pid, {:snapshot, ids}, :infinity)
  def collect(pid), do: GenServer.call(pid, :collect, :infinity)
  def close(pid), do: GenServer.call(pid, :close, :infinity)

  @doc false
  def checkpoint(pid, budget) do
    with :ok <- GenServer.call(pid, :freeze), do: await_checkpoint(pid, budget)
  end

  defp await_checkpoint(pid, budget) do
    with :ok <- Alto.Runner.Budget.check(budget) do
      case GenServer.call(pid, :checkpoint) do
        :pending ->
          Process.sleep(10)
          await_checkpoint(pid, budget)

        result ->
          result
      end
    end
  end

  @doc false
  def restore(pid, saved, run), do: GenServer.call(pid, {:restore, saved, run})
  @doc false
  def activate(pid), do: GenServer.call(pid, :activate)

  # A waiting child relinquishes its parent's concurrency slot. It must acquire
  # a slot again before it returns to model/tool execution.
  def park(nil), do: :ok
  def park({pid, id}), do: GenServer.call(pid, {:park, id}, :infinity)
  def resume(nil), do: :ok
  def resume({pid, id}), do: GenServer.call(pid, {:resume, id}, :infinity)

  @impl true
  def init(owner),
    do: {:ok, %{owner: Process.monitor(owner), entries: [], limit: 1, frozen: false}}

  @impl true
  def handle_call({:submit, specs, run}, _from, state) do
    if length(state.entries) + length(specs) > 256 do
      {:reply, {:error, :agent_capacity}, state}
    else
      entries = Enum.map(specs, &new_entry(&1, run))
      send(self(), :dispatch)
      next = %{state | entries: state.entries ++ entries, limit: run.child_limits.max_concurrency}
      {:reply, {:ok, Enum.map(entries, &public/1)}, next}
    end
  end

  def handle_call(:freeze, _, state) do
    Enum.each(state.entries, fn entry ->
      if live?(entry), do: Alto.Messaging.pause(entry.spec.messaging)
    end)

    {:reply, :ok, %{state | frozen: true}}
  end

  def handle_call(:checkpoint, _, state) do
    if Enum.any?(state.entries, &live?/1) do
      {:reply, :pending, state}
    else
      saved =
        Enum.map(state.entries, fn entry ->
          entry
          |> Map.take([:id, :spec, :status, :summary, :collected])
          |> Map.update!(:spec, &Map.drop(&1, [:messaging, :agent_scheduler]))
        end)

      {:reply, {:ok, saved}, state}
    end
  end

  def handle_call({:restore, saved, run}, _, %{entries: []} = state) when is_list(saved) do
    with true <-
           length(saved) <= 256 and Enum.all?(saved, &valid_saved?/1) and
             length(Enum.uniq_by(saved, & &1.id)) == length(saved),
         {:ok, entries} <-
           Alto.Result.traverse(saved, fn e ->
             with {:ok, sender} <- Alto.Messaging.resolve(run.messaging.router, e.id) do
               {:ok,
                %{
                  new_entry(Map.put(e.spec, :messaging, sender), run)
                  | status: if(e.status == :suspended, do: :pending, else: e.status),
                    summary: e.summary,
                    collected: e.collected
                }}
             end
           end) do
      {:reply, :ok,
       %{state | entries: entries, frozen: true, limit: run.child_limits.max_concurrency}}
    else
      false -> {:reply, {:error, :invalid_async_checkpoint}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:restore, _, _}, _, state),
    do: {:reply, {:error, :invalid_async_checkpoint}, state}

  def handle_call(:activate, _, state) do
    send(self(), :dispatch)
    {:reply, :ok, %{state | frozen: false}}
  end

  def handle_call({:snapshot, ids}, _from, state) do
    entries = Map.new(state.entries, &{&1.id, &1})

    if Enum.all?(ids, &Map.has_key?(entries, &1)),
      do: {:reply, {:ok, Enum.map(ids, &public(entries[&1]))}, state},
      else: {:reply, {:error, :unknown_agent}, state}
  end

  def handle_call(:collect, _from, state) do
    {summaries, state} = collect_summaries(state)
    {:reply, summaries, state}
  end

  def handle_call({:park, id}, _from, state) do
    send(self(), :dispatch)
    {:reply, :ok, update_status(state, id, :waiting)}
  end

  def handle_call({:resume, id}, _from, state) do
    case Enum.find(state.entries, &(&1.id == id)) do
      %{status: :running} ->
        {:reply, :ok, state}

      %{status: status} when status in [:waiting, :resuming] ->
        if active(state) < state.limit,
          do: {:reply, :ok, update_status(state, id, :running)},
          else: {:reply, :wait, update_status(state, id, :resuming)}

      _ ->
        {:reply, {:error, :agent_closed}, state}
    end
  end

  def handle_call(:close, _from, state) do
    {summaries, state} = state |> stop_children() |> collect_summaries()
    {:reply, summaries, state}
  end

  @impl true
  def handle_info(:dispatch, state), do: {:noreply, dispatch(state)}

  def handle_info({ref, outcome}, state) when is_reference(ref) do
    next =
      update_entries(state, &(&1.starter && &1.starter.ref == ref), fn entry ->
        Process.demonitor(ref, [:flush])
        started(entry, outcome)
      end)

    {:noreply, dispatch(next)}
  end

  def handle_info({:alto_runner_result, ref, outcome}, state) when is_reference(ref),
    do:
      {:noreply,
       state |> update_entries(&(&1.ref == ref), &finish(&1, outcome, true)) |> dispatch()}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state),
    do: {:stop, :normal, stop_children(state)}

  def handle_info({:DOWN, ref, :process, _, reason}, state),
    do: handle_info({ref, {:error, {:run_process_failed, {:child_start_failed, reason}}}}, state)

  def handle_info(_, state), do: {:noreply, state}

  defp started(entry, {:ok, handle}) do
    case Runner.subscribe(handle) do
      {:ok, ref} ->
        %{
          entry
          | starter: nil,
            handle: handle,
            ref: ref,
            run: nil,
            status: if(entry.status == :starting, do: :running, else: entry.status)
        }

      {:error, reason} ->
        finish(entry, Runner.terminate(handle, {:subscription_failed, reason}))
    end
  end

  defp started(entry, {:error, _} = outcome), do: finish(entry, outcome)

  defp dispatch(%{frozen: true} = state), do: state

  defp dispatch(state) do
    entry = Enum.find(state.entries, &(&1.status in [:pending, :resuming]))

    if entry && active(state) < state.limit do
      next =
        if entry.status == :resuming do
          %{entry | status: :running}
        else
          spec = Map.put(entry.spec, :agent_scheduler, {self(), entry.id})

          starter =
            Alto.Runner.Execution.Call.start(fn -> Children.start_subagent(spec, entry.run) end)

          %{entry | starter: starter, status: :starting}
        end

      state |> update_entries(&(&1.id == entry.id), fn _ -> next end) |> dispatch()
    else
      state
    end
  end

  defp finish(entry, outcome, retain_checkpoint? \\ false) do
    Alto.Messaging.close(entry.spec.messaging)
    entry = %{entry | starter: nil, handle: nil, ref: nil, run: nil}

    case outcome do
      {:error, :execution_suspended, %{checkpoint: packet}} when retain_checkpoint? ->
        %{
          entry
          | status: :suspended,
            summary: nil,
            spec: Map.put(entry.spec, :async_checkpoint, packet)
        }

      _ ->
        %{entry | status: :completed, summary: Children.child_summary(entry.spec.id, outcome)}
    end
  end

  defp new_entry(spec, run) do
    %{
      id: spec.messaging.id,
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
    }
  end

  defp valid_saved?(%{id: id, spec: spec, status: status, summary: _, collected: collected}),
    do:
      is_binary(id) and is_map(spec) and status in [:pending, :suspended, :completed] and
        is_boolean(collected)

  defp valid_saved?(_), do: false

  defp live?(entry), do: entry.status in [:starting, :running, :waiting, :resuming]
  defp active(state), do: Enum.count(state.entries, &(&1.status in [:starting, :running]))

  defp update_status(state, id, status),
    do: update_entries(state, &(&1.id == id), &%{&1 | status: status})

  defp update_entries(state, predicate, change),
    do: %{
      state
      | entries:
          Enum.map(state.entries, fn entry ->
            if predicate.(entry), do: change.(entry), else: entry
          end)
    }

  defp public(entry) do
    base = %{agent_id: entry.id, id: entry.spec.id, status: entry.status}

    if entry.summary,
      do: Map.put(base, :result, Children.public_child_summary(entry.summary)),
      else: base
  end

  defp collect_summaries(state) do
    {entries, summaries} =
      Enum.map_reduce(state.entries, [], fn
        %{summary: summary, collected: false} = entry, summaries when not is_nil(summary) ->
          {%{entry | collected: true}, [summary | summaries]}

        entry, summaries ->
          {entry, summaries}
      end)

    {summaries, %{state | entries: entries}}
  end

  defp stop_children(state) do
    Enum.each(state.entries, fn entry ->
      if entry.handle && live?(entry), do: Runner.cancel(entry.handle, :parent_finished)
    end)

    deadline = System.monotonic_time(:millisecond) + 1_000
    %{state | entries: Enum.map(state.entries, &stop_child(&1, deadline))}
  end

  defp stop_child(%{status: status} = entry, _) when status in [:completed, :suspended], do: entry

  defp stop_child(%{starter: %Task{} = starter} = entry, _) do
    outcome =
      case Task.shutdown(starter, :brutal_kill) do
        {:ok, {:ok, handle}} ->
          Runner.cancel(handle, :parent_finished)
          Runner.terminate(handle, :parent_finished)

        _ ->
          {:error, {:run_process_failed, :child_start_interrupted}}
      end

    finish(entry, outcome)
  end

  defp stop_child(%{handle: nil} = entry, _),
    do: finish(entry, {:error, {:not_started, :parent_finished}})

  defp stop_child(entry, deadline) do
    outcome =
      case Runner.await(entry.handle, max(deadline - System.monotonic_time(:millisecond), 0)) do
        {:error, :await_timeout} -> Runner.terminate(entry.handle, :parent_finished)
        outcome -> outcome
      end

    finish(entry, outcome)
  end
end
