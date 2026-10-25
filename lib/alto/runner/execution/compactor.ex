defmodule Alto.Runner.Execution.Compactor do
  @moduledoc false
  use GenServer

  alias Alto.Runner.Execution.Call
  alias Alto.Usage

  # This scope belongs to one execution, including executions restored from a
  # checkpoint. Neither workers nor their process identities are checkpointed.
  def scope(opts, fun) when is_list(opts) do
    if Keyword.get(opts, :compaction, false) in [false, nil],
      do: fun.(opts),
      else: with_server(fn pid -> fun.(Keyword.put(opts, :compactor, pid)) end)
  end

  def scope(%{compactor: pid} = run, fun) when is_pid(pid), do: fun.(run)

  def scope(run, fun) when is_map(run) do
    with_server(fn pid ->
      case fun.(Map.put(run, :compactor, pid)) do
        {:ok, next} -> {:ok, Map.delete(next, :compactor)}
        {:error, reason, next} -> {:error, reason, Map.delete(next, :compactor)}
      end
    end)
  end

  defp with_server(fun) do
    {:ok, pid} = GenServer.start_link(__MODULE__, nil)
    Call.with_server(pid, fun)
  end

  def background?(run), do: is_list(run.compaction) and run.compaction[:mode] == :background

  def enabled?(run), do: is_pid(Map.get(run, :compactor))

  def start(run, snapshot, fun),
    do: GenServer.call(run.compactor, {:start, snapshot, fun}, :infinity)

  def pending?(run), do: enabled?(run) and GenServer.call(run.compactor, :pending?)

  def take(run, wait \\ false),
    do: GenServer.call(run.compactor, if(wait, do: :await, else: :take), :infinity)

  def cancel(run) do
    if enabled?(run), do: GenServer.call(run.compactor, :cancel, :infinity)
    sync(run)
  end

  # Foreground and reducer calls reserve local max_steps slots together, while
  # Model.request still reserves each transport attempt from the shared Budget.
  def reserve_model(run) do
    if enabled?(run) do
      GenServer.call(
        run.compactor,
        {:reserve_model, run.model_requests, run.max_steps,
         Map.get(run, :compaction_model, false)}
      )
    else
      if is_integer(run.max_steps) and run.model_requests >= run.max_steps,
        do: {:error, {:model_step_limit, run.max_steps}},
        else: {:ok, run.model_requests + 1}
    end
  end

  def account(run, evidence) do
    if Map.get(run, :compaction_model, false) do
      GenServer.call(run.compactor, {:account, evidence})
    end
  end

  # Drain deltas, never merge an old snapshot's counters over foreground work.
  # Keep latest-request usage tied to foreground work when one has completed.
  def sync(run) do
    if enabled?(run) do
      %{count: count, usage: usage, attempts: attempts} =
        GenServer.call(run.compactor, :drain)

      merged =
        if background?(run),
          do: Usage.merge(usage, run.usage),
          else: Usage.merge(run.usage, usage)

      Map.merge(run, %{
        model_requests: run.model_requests + count,
        usage: merged,
        provider_attempts: Enum.take(Map.get(run, :provider_attempts, []) ++ attempts, -32)
      })
    else
      run
    end
  end

  @impl true
  def init(_) do
    {:ok, %{job: nil, steps: 0, accounting: empty_accounting()}}
  end

  @impl true
  def handle_call({:start, snapshot, fun}, _from, %{job: nil} = state) do
    task = Call.start(fun)

    {:reply, :ok,
     %{state | job: %{task: task, snapshot: snapshot, result: :pending, waiter: nil}}}
  end

  def handle_call({:start, _, _}, _from, state), do: {:reply, :pending, state}

  def handle_call(:pending?, _from, state), do: {:reply, state.job != nil, state}

  def handle_call(kind, from, state) when kind in [:take, :await] do
    case state.job do
      nil -> {:reply, :idle, state}
      %{result: :pending} when kind == :await -> {:noreply, put_in(state.job.waiter, from)}
      %{result: :pending} -> {:reply, :pending, state}
      job -> {:reply, {:ready, job.snapshot, job.result}, %{state | job: nil}}
    end
  end

  def handle_call(:cancel, _from, state) do
    stop_job(state.job)
    {:reply, :ok, %{state | job: nil}}
  end

  def handle_call({:reserve_model, count, limit, reducer?}, _from, state) do
    steps = max(state.steps, count)

    cond do
      reducer? and state.job == nil ->
        {:reply, {:error, :reduction_model_closed}, state}

      is_integer(limit) and steps >= limit ->
        {:reply, {:error, {:model_step_limit, limit}}, state}

      true ->
        state =
          if reducer?,
            do: update_in(state.accounting.count, &(&1 + 1)),
            else: state

        {:reply, {:ok, steps + 1}, %{state | steps: steps + 1}}
    end
  end

  def handle_call({:account, evidence}, _from, state) do
    accounting = %{
      count: state.accounting.count,
      usage: Usage.merge(state.accounting.usage, Usage.normalize(evidence.usage)),
      attempts: Enum.take(state.accounting.attempts ++ [evidence], -32)
    }

    {:reply, :ok, %{state | accounting: accounting}}
  end

  def handle_call(:drain, _from, state),
    do: {:reply, state.accounting, %{state | accounting: empty_accounting()}}

  @impl true
  def handle_info({ref, result}, %{job: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    completed(state, result)
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{job: %{task: %{ref: ref}}} = state),
    do: completed(state, {:error, {:participant_failed, reason}})

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: stop_job(state.job)

  defp completed(%{job: %{waiter: nil}} = state, result),
    do: {:noreply, put_in(state.job.result, result)}

  defp completed(state, result) do
    GenServer.reply(state.job.waiter, {:ready, state.job.snapshot, result})
    {:noreply, %{state | job: nil}}
  end

  defp stop_job(nil), do: :ok
  defp stop_job(job), do: Task.shutdown(job.task, :brutal_kill)

  defp empty_accounting, do: %{count: 0, usage: Usage.new(), attempts: []}
end
