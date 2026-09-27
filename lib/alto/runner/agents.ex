defmodule Alto.Runner.Agents do
  @moduledoc "Child scheduling for nonblocking start and interruptible joins."
  use GenServer
  alias Alto.Runner
  alias Alto.Runner.Execution.Children

  def batch(specs, concurrency, start, check, opts \\ []) do
    runner = Keyword.get(opts, :runner, Runner)
    {:ok, pid} = GenServer.start(__MODULE__, {self(), specs, concurrency, start, runner, opts})

    try do
      await_batch(pid, check)
    after
      if Process.alive?(pid) do
        GenServer.call(pid, {:close, :parent_finished}, :infinity)
        GenServer.stop(pid)
      end
    end
  end

  defp await_batch(pid, check) do
    case check.() do
      :continue ->
        case GenServer.call(pid, :batch_results, :infinity) do
          :pending ->
            Process.sleep(20)
            await_batch(pid, check)

          outcomes ->
            {:ok, outcomes}
        end

      status ->
        {status, GenServer.call(pid, {:close, status}, :infinity)}
    end
  end

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
  def init({owner, specs, concurrency, start, runner, opts}) do
    {:ok, state} = init(owner)

    {:ok,
     %{
       state
       | entries: Enum.map(specs, &new_entry(&1, nil, opts)),
         limit: concurrency,
         frozen: true,
         start: start,
         runner: runner
     }}
  end

  def init(owner),
    do:
      {:ok,
       %{
         owner: Process.monitor(owner),
         entries: [],
         limit: 1,
         frozen: false,
         start: nil,
         runner: Runner
       }}

  @impl true
  def handle_call({:submit, specs, run}, _from, state) do
    if length(state.entries) + length(specs) > 256 do
      {:reply, {:error, :agent_capacity}, state}
    else
      entries = Enum.map(specs, &new_entry(&1, run))
      Enum.each(entries, &notify_status/1)
      send(self(), :dispatch)
      next = %{state | entries: state.entries ++ entries, limit: run.child_limits.max_concurrency}
      {:reply, {:ok, Enum.map(entries, &public/1)}, next}
    end
  end

  def handle_call(:batch_results, _, state) do
    if Enum.all?(state.entries, &(&1.status == :completed)) do
      {:reply, batch_outcomes(state), state}
    else
      next = dispatch(%{state | frozen: false})
      {:reply, :pending, %{next | frozen: true}}
    end
  end

  def handle_call({:close, reason}, _, state) do
    state = stop_children(state, reason)
    {:reply, batch_outcomes(state), %{state | frozen: true}}
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
        started(entry, outcome, state.runner)
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

  defp started(entry, {:ok, handle}, runner) do
    case runner.subscribe(handle, self()) do
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
        finish(entry, runner.terminate(handle, {:subscription_failed, reason}))
    end
  end

  defp started(entry, {:error, _} = outcome, _runner), do: finish(entry, outcome)

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
            Alto.Runner.Execution.Call.start(fn ->
              if state.start,
                do: state.start.(entry.spec),
                else: Children.start_subagent(spec, entry.run)
            end)

          %{entry | starter: starter, status: :starting}
        end

      state |> update_entries(&(&1.id == entry.id), fn _ -> next end) |> dispatch()
    else
      state
    end
  end

  defp finish(entry, outcome, retain_checkpoint? \\ false) do
    if entry.spec[:messaging], do: Alto.Messaging.close(entry.spec.messaging)
    entry = %{entry | starter: nil, handle: nil, ref: nil, run: nil}

    next =
      case {entry.batch?, outcome} do
        {true, _} ->
          %{entry | status: :completed, outcome: outcome}

        {false,
         %Alto.Runner.Result{status: :suspended, reason: :execution_suspended, checkpoint: packet}}
        when retain_checkpoint? ->
          %{
            entry
            | status: :suspended,
              summary: nil,
              spec: Map.put(entry.spec, :async_checkpoint, packet)
          }

        _ ->
          %{entry | status: :completed, summary: Children.child_summary(entry.spec.id, outcome)}
      end

    notify_status(next)
    next
  end

  defp notify_status(entry) do
    summary =
      entry.summary || if(entry.outcome, do: Children.child_summary(entry.spec.id, entry.outcome))

    data = %{
      agent_id: if(entry.spec[:messaging], do: entry.spec.messaging.id, else: entry.id),
      id: entry.spec.id,
      parent: entry.parent,
      status: entry.status,
      model: entry.spec[:model],
      backend: entry.spec[:profile_key],
      result: summary && Map.take(summary, [:status, :reason, :output, :session_id, :usage])
    }

    Alto.Events.notify(entry.event_sink, Alto.Event.live(:subagent_status, data))
  end

  defp new_entry(spec, run, opts \\ []) do
    %{
      id: if(run, do: spec.messaging.id, else: spec.id),
      event_sink: if(run, do: run.event_sink, else: opts[:event_sink]),
      parent: if(run, do: run.messaging.id, else: opts[:parent]),
      spec: spec,
      run:
        if(run,
          do:
            run
            |> Map.drop([:messages_rev, :events_rev, :loop_state])
            |> Map.put(:execution_owner, self())
        ),
      starter: nil,
      handle: nil,
      ref: nil,
      status: :pending,
      summary: nil,
      outcome: nil,
      batch?: is_nil(run),
      collected: false
    }
  end

  defp valid_saved?(%{id: id, spec: spec, status: status, summary: summary, collected: collected}) do
    is_binary(id) and is_map(spec) and is_boolean(collected) and
      case status do
        :completed -> Children.validate_child_summary(spec[:id], summary) == :ok
        status when status in [:pending, :suspended] -> is_nil(summary)
        _ -> false
      end
  end

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
            if predicate.(entry) do
              next = change.(entry)

              if next.status != entry.status and next.status not in [:completed, :suspended],
                do: notify_status(next)

              next
            else
              entry
            end
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

  defp batch_outcomes(state), do: Enum.map(state.entries, &{&1.spec.id, &1.outcome})

  defp stop_children(state, reason \\ :parent_finished) do
    deadline = System.monotonic_time(:millisecond) + if(state.start, do: 5_000, else: 1_000)

    entries =
      Enum.map(state.entries, fn
        %{starter: %Task{} = starter} = entry ->
          case Task.shutdown(starter, :brutal_kill) do
            {:ok, outcome} -> started(entry, outcome, state.runner)
            _ -> finish(entry, {:error, {:run_process_failed, :child_start_interrupted}})
          end

        %{status: :pending} = entry ->
          finish(entry, {:error, {:not_started, reason}})

        entry ->
          entry
      end)

    Enum.each(entries, fn entry ->
      if entry.handle && live?(entry), do: state.runner.cancel(entry.handle, reason)
    end)

    drain(%{state | entries: entries, frozen: true}, deadline, reason)
  end

  defp drain(state, deadline, reason) do
    refs = for entry <- state.entries, entry.ref, into: %{}, do: {entry.ref, true}

    if map_size(refs) == 0 do
      state
    else
      receive do
        {:alto_runner_result, ref, outcome} when is_map_key(refs, ref) ->
          state
          |> update_entries(&(&1.ref == ref), &finish(&1, outcome))
          |> drain(deadline, reason)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          update_entries(state, &(&1.ref != nil), fn entry ->
            finish(entry, state.runner.terminate(entry.handle, reason))
          end)
      end
    end
  end
end
