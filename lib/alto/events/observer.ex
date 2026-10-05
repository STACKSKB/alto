defmodule Alto.Events.Observer do
  @moduledoc """
  Owner-scoped, bounded, ordered delivery for slow host observers.

  `push/2` acknowledges admission, not delivery. No accepted durable event is
  coalesced or silently discarded. Call `close/2` to drain and inspect delivery
  errors. Overflow rejects admission and is also reflected in the drain result.
  Live text deltas can coalesce only at the queued tail with identical attribution.
  Callback failures/timeouts are reported; subsequent accepted events still run
  in order. Session persistence remains owned by the execution host.
  """
  use GenServer
  alias Alto.Event
  alias Alto.Runner.Execution.Call

  def open(sink, opts \\ []) when is_function(sink, 1) do
    schema = [
      max_events: [type: :pos_integer, default: 128],
      max_bytes: [type: :pos_integer, default: 2_000_000],
      callback_timeout: [type: :pos_integer, default: 250],
      coalesce: [type: :boolean, default: true]
    ]

    with {:ok, opts} <- NimbleOptions.validate(opts, schema),
         do: GenServer.start(__MODULE__, {self(), sink, Map.new(opts)})
  end

  def sink(pid), do: fn event -> push(pid, event) end
  def push(pid, event), do: call(pid, {:push, event}, 1_000)
  def close(pid, timeout \\ 5_000), do: call(pid, :close, timeout)

  defp call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :observer_wait_timeout}
    :exit, _ -> {:error, :observer_closed}
  end

  @impl true
  def init({owner, sink, limits}) do
    {:ok,
     %{
       owner: Process.monitor(owner),
       sink: sink,
       limits: limits,
       queue: :queue.new(),
       count: 0,
       bytes: 0,
       worker: nil,
       closer: nil,
       stats: %{accepted: 0, delivered: 0, rejected: 0, coalesced: 0, callback_ms: 0, errors: []}
     }}
  end

  @impl true
  def handle_call({:push, _event}, _from, %{closer: closer} = state) when not is_nil(closer),
    do: {:reply, {:error, :observer_closing}, state}

  def handle_call({:push, event}, _from, state) do
    size = :erlang.external_size(event)

    case coalesce(state, event, size) do
      {:ok, next} ->
        {:reply, :ok, next}

      :no ->
        if state.count < state.limits.max_events and state.bytes + size <= state.limits.max_bytes do
          state = %{
            state
            | queue: :queue.in({event, size}, state.queue),
              count: state.count + 1,
              bytes: state.bytes + size,
              stats: Map.update!(state.stats, :accepted, &(&1 + 1))
          }

          {:reply, :ok, dispatch(state)}
        else
          state =
            %{state | stats: Map.update!(state.stats, :rejected, &(&1 + 1))}
            |> failure(:observer_overloaded)

          {:reply, {:error, :observer_overloaded}, state}
        end
    end
  end

  def handle_call(:close, from, %{closer: nil} = state), do: settle(%{state | closer: from})
  def handle_call(:close, _, state), do: {:reply, {:error, :observer_closing}, state}

  @impl true
  def handle_info({ref, result}, %{worker: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    done(state, result)
  end

  def handle_info({:callback_timeout, ref}, %{worker: %{task: %{ref: ref} = task}} = state) do
    Task.shutdown(task, :brutal_kill)
    done(state, {:error, :callback_timeout})
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: %{task: %{ref: ref}}} = state),
    do: done(state, {:error, :callback_failed})

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{worker: %{task: task}}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

  defp dispatch(%{worker: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {event, size}}, queue} ->
        sink = state.sink

        task =
          Call.start(fn ->
            try do
              case sink.(event) do
                {:error, _} -> {:error, :callback_rejected}
                _ -> :ok
              end
            catch
              _, _ -> {:error, :callback_failed}
            end
          end)

        timer =
          Process.send_after(self(), {:callback_timeout, task.ref}, state.limits.callback_timeout)

        %{
          state
          | queue: queue,
            worker: %{
              task: task,
              timer: timer,
              size: size,
              started: System.monotonic_time(:microsecond)
            }
        }

      {:empty, _} ->
        state
    end
  end

  defp dispatch(state), do: state

  defp done(state, result) do
    worker = state.worker
    Process.cancel_timer(worker.timer)

    stats =
      Map.update!(
        state.stats,
        :callback_ms,
        &(&1 + (System.monotonic_time(:microsecond) - worker.started) / 1000)
      )

    state = %{
      state
      | worker: nil,
        count: state.count - 1,
        bytes: state.bytes - worker.size,
        stats: stats
    }

    state =
      case result do
        :ok -> %{state | stats: Map.update!(state.stats, :delivered, &(&1 + 1))}
        {:error, error} -> failure(state, error)
      end

    state |> dispatch() |> settle()
  end

  defp settle(%{count: 0, closer: from} = state) when not is_nil(from) do
    status = if state.stats.errors == [], do: {:ok, state.stats}, else: {:error, state.stats}
    GenServer.reply(from, status)
    {:stop, :normal, state}
  end

  defp settle(state), do: {:noreply, state}

  defp failure(state, error),
    do: %{
      state
      | stats: Map.update!(state.stats, :errors, &Enum.take(Enum.uniq(&1 ++ [error]), 16))
    }

  defp coalesce(
         %{limits: %{coalesce: true}} = state,
         %Event{domain: :live, type: type, data: %{text: text}} = event,
         _size
       )
       when type in [:model_delta, :model_reasoning_delta] and is_binary(text) do
    case :queue.out_r(state.queue) do
      {{:value, {%Event{domain: :live, type: ^type, data: %{text: prior}} = last, size}}, rest} ->
        if Map.delete(last.data, :text) == Map.delete(event.data, :text) do
          merged = %{last | data: Map.put(last.data, :text, prior <> text)}
          bytes = :erlang.external_size(merged)

          if state.bytes - size + bytes <= state.limits.max_bytes do
            {:ok,
             %{
               state
               | queue: :queue.in({merged, bytes}, rest),
                 bytes: state.bytes - size + bytes,
                 stats:
                   state.stats
                   |> Map.update!(:accepted, &(&1 + 1))
                   |> Map.update!(:coalesced, &(&1 + 1))
             }}
          else
            :no
          end
        else
          :no
        end

      _ ->
        :no
    end
  end

  defp coalesce(_, _, _), do: :no
end
