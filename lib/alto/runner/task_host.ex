defmodule Alto.Runner.TaskHost do
  @moduledoc """
  Optional supervised-task lifecycle for execution hosts.

  Owns task replies, cancellation, crash outcomes, and completion subscriptions.
  Hosts supply a function accepting a cancellation reference. Completed handles
  remain available for 60 seconds after completion, independently of the creating process.
  Other runner implementations can supply an entirely different lifecycle.
  """
  use GenServer
  alias Alto.Runner.Result

  defmodule Handle do
    @moduledoc false
    @enforce_keys [:pid]
    defstruct [:pid]
    @opaque t :: %__MODULE__{pid: pid()}
  end

  def start(fun, opts) when is_function(fun, 1) do
    owner = Keyword.get(opts, :owner)

    if is_nil(owner) or is_pid(owner) do
      case DynamicSupervisor.start_child(Alto.AgentSupervisor, {__MODULE__, {fun, owner}}) do
        {:ok, pid} -> {:ok, %Handle{pid: pid}}
        {:error, reason} -> {:error, {:run_start_failed, reason}}
      end
    else
      {:error, {:invalid_owner, owner}}
    end
  end

  def child_spec(arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  def await(handle, timeout \\ :infinity), do: call(handle, {:await, timeout})
  def cancel(handle, reason \\ :user), do: call(handle, {:cancel, reason})
  @impl true
  def terminate(handle, reason \\ :cancel_timeout)
  def terminate(%Handle{} = handle, reason), do: call(handle, {:terminate, reason})
  def terminate(_reason, %{task: task, result: nil}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_reason, _state), do: :ok

  def subscribe(%Handle{pid: host}, pid \\ self()) when is_pid(pid) do
    ref = make_ref()
    caller = self()
    spawn(fn -> observe(host, pid, caller, ref) end)

    receive do
      {:subscribed, ^ref, reply} -> reply
    end
  end

  defp observe(host, subscriber, caller, ref) do
    host_ref = Process.monitor(host)
    subscriber_ref = Process.monitor(subscriber)

    case call(%Handle{pid: host}, {:subscribe, self(), ref}) do
      :ok ->
        send(caller, {:subscribed, ref, {:ok, ref}})

        receive do
          {:alto_runner_result, ^ref, outcome} ->
            send(subscriber, {:alto_runner_result, ref, outcome})

          {:DOWN, ^host_ref, :process, _, reason} ->
            send(subscriber, {:alto_runner_result, ref, failed(reason)})

          {:DOWN, ^subscriber_ref, :process, _, _} ->
            :ok
        end

      {:error, _} = error ->
        send(caller, {:subscribed, ref, error})
    end
  end

  defp call(%Handle{pid: pid}, request) do
    GenServer.call(pid, request, :infinity)
  catch
    :exit, reason ->
      case request do
        {:cancel, _} -> :already_finished
        {:subscribe, _, _} -> {:error, {:run_unavailable, reason}}
        _ -> failed(reason)
      end
  end

  @impl true
  def init({fun, owner}) do
    cancel_ref = make_ref()
    task = Task.Supervisor.async_nolink(Alto.TaskSupervisor, fn -> fun.(cancel_ref) end)

    {:ok,
     %{
       task: task,
       cancel_ref: cancel_ref,
       result: nil,
       subscribers: [],
       waiters: %{},
       owner: if(owner, do: Process.monitor(owner)),
       expiry: nil
     }}
  end

  @impl true
  def handle_call({:await, _timeout}, _from, %{result: result} = state) when not is_nil(result),
    do: {:reply, result, state}

  def handle_call({:await, 0}, _from, state), do: {:reply, {:error, :await_timeout}, state}

  def handle_call({:await, timeout}, from, state)
      when timeout == :infinity or (is_integer(timeout) and timeout > 0) do
    ref = Process.monitor(elem(from, 0))
    timer = if timeout != :infinity, do: Process.send_after(self(), {:wait_expired, ref}, timeout)
    {:noreply, put_in(state.waiters[ref], {from, timer})}
  end

  def handle_call({:subscribe, pid, ref}, _from, state) when is_pid(pid) do
    cond do
      state.result != nil ->
        send(pid, {:alto_runner_result, ref, state.result})
        {:reply, :ok, state}

      length(state.subscribers) >= 1024 ->
        {:reply, {:error, :subscriber_capacity}, state}

      true ->
        {:reply, :ok, %{state | subscribers: [{pid, ref} | state.subscribers]}}
    end
  end

  def handle_call({:cancel, reason}, _from, %{result: nil} = state) do
    send(state.task.pid, {:alto_cancel, state.cancel_ref, reason})
    {:reply, :ok, state}
  end

  def handle_call({:cancel, _reason}, _from, state), do: {:reply, :already_finished, state}

  def handle_call({:terminate, reason}, _from, %{result: nil} = state) do
    outcome =
      case Task.shutdown(state.task, :brutal_kill) do
        {:ok, outcome} -> outcome
        _ -> failed(reason)
      end

    {:reply, outcome, complete(state, outcome)}
  end

  def handle_call({:terminate, _}, _from, state), do: {:reply, state.result, state}

  @impl true
  def handle_info({ref, outcome}, %{task: %{ref: ref}, result: nil} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, complete(state, outcome)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      ref == state.task.ref and state.result == nil ->
        {:noreply, complete(state, failed(reason))}

      ref == state.owner ->
        if state.result == nil,
          do: send(state.task.pid, {:alto_cancel, state.cancel_ref, {:owner_down, reason}})

        {:noreply, state}

      Map.has_key?(state.waiters, ref) ->
        {_from, timer} = state.waiters[ref]
        cancel_timer(timer)
        {:noreply, %{state | waiters: Map.delete(state.waiters, ref)}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:wait_expired, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer}, waiters} ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, {:error, :await_timeout})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info(:expire, state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  defp complete(state, outcome) do
    Enum.each(state.subscribers, fn {pid, ref} ->
      send(pid, {:alto_runner_result, ref, outcome})
    end)

    Enum.each(state.waiters, fn {ref, {from, timer}} ->
      Process.demonitor(ref, [:flush])
      cancel_timer(timer)
      GenServer.reply(from, outcome)
    end)

    expiry = Process.send_after(self(), :expire, 60_000)
    %{state | result: outcome, subscribers: [], waiters: %{}, expiry: expiry}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp failed(reason),
    do: {:error, {:run_process_failed, reason}, %{Result.empty() | verdict: :unknown}}
end
