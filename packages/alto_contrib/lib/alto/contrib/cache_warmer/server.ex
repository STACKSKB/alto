defmodule Alto.Contrib.CacheWarmer.Server do
  @moduledoc false
  use GenServer
  alias Alto.Runner.Execution.Call

  def start(args), do: GenServer.start(__MODULE__, args)
  def request(pid, request), do: safe_call(pid, {:request, request})
  def event(pid, event), do: safe_call(pid, {:event, event, self()})
  def subscribe(pid, ref), do: safe_call(pid, {:subscribe, ref})
  def stop(pid), do: safe_call(pid, :stop)
  # Explicit pulse plus injected monotonic clock keeps scheduling tests deterministic.
  def pulse(pid), do: safe_call(pid, :pulse)

  defp safe_call(pid, message) do
    GenServer.call(pid, message, 5_000)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(args) do
    clock = Map.get(args, :clock, fn -> System.monotonic_time(:millisecond) end)
    now = clock.()

    if is_nil(args.owner) or is_pid(args.owner) do
      Process.send_after(self(), :horizon, args.max_duration_ms)

      {:ok,
       Map.merge(args, %{
         clock: clock,
         expires: now + args.max_duration_ms,
         owner_ref: if(args.owner, do: Process.monitor(args.owner)),
         execution_ref: nil,
         subscription: nil,
         pending: nil,
         candidate: nil,
         tools: MapSet.new(),
         requests: 0,
         timer: nil,
         epoch: 0,
         worker: nil
       })}
    else
      {:stop, :invalid_owner}
    end
  end

  @impl true
  def handle_call({:subscribe, ref}, _, state), do: {:reply, :ok, %{state | subscription: ref}}
  def handle_call(:stop, _, state), do: {:stop, :normal, :ok, state}
  def handle_call(:pulse, _, state), do: {:reply, :ok, maybe_warm(state)}

  def handle_call({:request, %{run_id: id} = request}, _, %{run_id: id} = state) do
    started = state.clock.()

    pending =
      case safely(fn -> state.plan.(request) end) do
        {:ok, %{ttl_ms: ttl, bytes: bytes} = plan}
        when bytes <= state.max_prompt_bytes and ttl > state.refresh_margin_ms ->
          %{plan: plan, started: started, due: started + ttl - state.refresh_margin_ms}

        _ ->
          nil
      end

    {:reply, :ok, %{state | pending: pending}}
  end

  def handle_call({:request, _}, _, state), do: {:reply, :ok, state}

  def handle_call({:event, %{type: :model_started}, execution}, _, state) do
    state = clear(state, :superseded)
    ref = state.execution_ref || Process.monitor(execution)

    {:reply, :ok,
     %{state | pending: nil, candidate: nil, tools: MapSet.new(), execution_ref: ref}}
  end

  def handle_call({:event, %{type: :model_completed}, _}, _, state),
    do: {:reply, :ok, %{state | candidate: state.pending, pending: nil}}

  def handle_call({:event, %{type: :tool_started, data: data}, _}, _, state) do
    {:reply, :ok, schedule(%{state | tools: MapSet.put(state.tools, data.operation_id)})}
  end

  def handle_call({:event, %{type: kind, data: data}, _}, _, state)
      when kind in [:tool_completed, :tool_failed] do
    state = %{state | tools: MapSet.delete(state.tools, data.operation_id)}
    state = if MapSet.size(state.tools) == 0, do: clear(state, :tools_finished), else: state
    {:reply, :ok, state}
  end

  def handle_call({:event, %{type: :run_cancelled}, _}, _, state),
    do: {:stop, :normal, :ok, state}

  def handle_call({:event, _, _}, _, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(:horizon, state), do: {:stop, :normal, state}
  # Subscription can finish before its reference is attached; only this run has
  # this private process as a subscriber, so early terminal delivery is safe.
  def handle_info({:alto_runner_result, _, _}, state), do: {:stop, :normal, state}

  def handle_info({:tick, epoch}, %{epoch: epoch} = state),
    do: {:noreply, maybe_warm(%{state | timer: nil})}

  def handle_info({:tick, _}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{worker: %{task: %{ref: ref}} = worker} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | worker: nil}

    case result do
      {:ok, %{usage: usage, cache_hit: hit, output: output}} ->
        notify(state, :cache_warm_finished, %{
          usage: usage,
          cache_hit: hit,
          outcome: if(output, do: :unexpected_output, else: :ok)
        })

        if hit and not output do
          candidate = %{
            state.candidate
            | started: worker.started,
              due: worker.started + state.candidate.plan.ttl_ms - state.refresh_margin_ms
          }

          {:noreply, schedule(%{state | candidate: candidate})}
        else
          {:noreply, %{state | candidate: nil}}
        end

      {:error, {:invalid_cache_warm_response, usage}} ->
        notify(state, :cache_warm_finished, %{
          usage: usage,
          usage_unknown: true,
          outcome: :invalid_response
        })

        {:noreply, %{state | candidate: nil}}

      _ ->
        notify(state, :cache_warm_finished, %{usage: nil, usage_unknown: true, outcome: :error})
        {:noreply, %{state | candidate: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: %{task: %{ref: ref}}} = state) do
    notify(state, :cache_warm_finished, %{usage: nil, usage_unknown: true, outcome: :error})
    {:noreply, %{state | worker: nil, candidate: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state)
      when ref == state.owner_ref or ref == state.execution_ref,
      do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, %{
      requests: status.state.requests,
      refreshing: not is_nil(status.state.worker)
    })
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end

  defp safely(fun) do
    fun.()
  catch
    _, _ -> {:error, :cache_warming_failed}
  end

  @impl true
  def terminate(_, state) do
    clear(state, :stopped)
    :ok
  end

  defp schedule(%{candidate: nil} = state), do: state
  defp schedule(%{worker: worker} = state) when not is_nil(worker), do: state

  defp schedule(state) do
    cond do
      MapSet.size(state.tools) == 0 or state.requests >= state.max_requests ->
        state

      state.clock.() >= state.expires ->
        state

      state.timer != nil ->
        state

      true ->
        delay = max(0, min(state.candidate.due, state.expires) - state.clock.())
        %{state | timer: Process.send_after(self(), {:tick, state.epoch}, delay)}
    end
  end

  defp maybe_warm(%{candidate: nil} = state), do: state
  defp maybe_warm(%{worker: worker} = state) when not is_nil(worker), do: state

  defp maybe_warm(state) do
    now = state.clock.()

    cond do
      now >= state.expires ->
        clear(%{state | candidate: nil}, :horizon)

      MapSet.size(state.tools) == 0 or state.requests >= state.max_requests ->
        state

      now < state.candidate.due ->
        schedule(state)

      now >= state.candidate.started + state.candidate.plan.ttl_ms ->
        %{state | candidate: nil}

      true ->
        state = cancel_timer(state)
        timeout = min(state.request_timeout_ms, state.expires - now)
        plan = state.candidate.plan
        refresh = state.refresh

        task =
          Call.start(fn ->
            Call.run(fn -> safely(fn -> refresh.(plan, timeout) end) end, timeout, nil)
          end)

        state = %{state | requests: state.requests + 1, worker: %{task: task, started: now}}
        notify(state, :cache_warm_started, %{attempt: state.requests})
        state
    end
  end

  defp clear(state, reason) do
    state = cancel_timer(state)

    if state.worker do
      Task.shutdown(state.worker.task, :brutal_kill)
      notify(state, :cache_warm_finished, %{usage: nil, usage_unknown: true, outcome: reason})
    end

    %{state | worker: nil}
  end

  defp cancel_timer(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: nil, epoch: state.epoch + 1}
  end

  defp notify(state, type, data) do
    # Host callbacks cannot indefinitely pin this process, its timer or credentials.
    timeout = min(100, max(0, state.expires - state.clock.()))

    Call.run(
      fn ->
        Alto.Events.notify(
          state.sink,
          Alto.Event.live(type, Map.put(data, :run_id, state.run_id))
        )
      end,
      timeout,
      nil
    )

    :ok
  end
end
