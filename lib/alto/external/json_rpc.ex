defmodule Alto.External.JSONRPC do
  @moduledoc false

  alias Alto.External.Process, as: ExternalProcess

  def state(opts, protocol_state) when is_map(protocol_state) do
    Map.merge(
      %{
        opts: opts,
        process: nil,
        buffer: "",
        phase: :starting,
        next_id: 1,
        pending: %{},
        ready_waiters: [],
        initialize_timer: nil
      },
      protocol_state
    )
  end

  def start_link(module, opts),
    do: GenServer.start_link(module, opts, name: Keyword.get(opts, :name))

  def child_spec(module, opts) do
    %{
      id: {module, Keyword.get(opts, :name)},
      start: {module, :start_link, [opts]},
      restart: :temporary
    }
  end

  def ensure_started(module, opts) do
    # Keyword lookup uses the first occurrence; option order is not client identity.
    identity = opts |> Enum.reverse() |> Map.new() |> :erlang.term_to_binary([:deterministic])
    key = {module, :crypto.hash(:sha256, identity)}
    name = {:via, Registry, {Alto.External.Registry, key}}
    child = {module, Keyword.put(opts, :name, name)}

    case DynamicSupervisor.start_child(Alto.External.Supervisor, child) do
      {:ok, pid} ->
        await_startup(pid, opts, module)

      {:error, {:already_started, pid}} ->
        await_startup(pid, opts, module)

      {:error, reason} ->
        {:error, {:external_client_failed, module, :start, reason}}
    end
  catch
    :exit, reason -> {:error, {:external_client_failed, module, :supervisor, reason}}
  end

  defp await_startup(pid, opts, module) do
    GenServer.call(pid, :await_ready, call_timeout(Keyword.fetch!(opts, :startup_timeout)))
  catch
    :exit, reason -> {:error, {:external_client_failed, module, :ready, reason}}
  end

  def call_timeout(:infinity), do: :infinity
  def call_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout + 100

  def open(state, opener, initialize) do
    case opener.(state.opts) do
      {:ok, process} ->
        state = %{state | process: process}

        case initialize.(state) do
          {:ok, state} -> {:ok, arm_startup_timeout(state)}
          {:error, reason} -> {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def format_status(status) do
    Map.update(status, :state, %{}, fn state ->
      %{phase: state.phase, pending_count: map_size(state.pending)}
    end)
    |> Map.put(:message, :redacted)
  end

  def await_ready(%{phase: :ready} = state, _from, _limit_error),
    do: {:reply, {:ok, self()}, state}

  def await_ready(%{phase: {:failed, reason}} = state, _from, _limit_error),
    do: {:reply, {:error, reason}, state}

  def await_ready(state, from, limit_error) do
    limit = Keyword.fetch!(state.opts, :max_ready_waiters)

    if length(state.ready_waiters) >= limit do
      {:reply, {:error, {limit_error, limit}}, state}
    else
      monitor = Process.monitor(elem(from, 0))
      {:noreply, %{state | ready_waiters: [{from, monitor} | state.ready_waiters]}}
    end
  end

  def ready(state) do
    cancel_timer(state.initialize_timer)

    Enum.each(state.ready_waiters, fn {from, monitor} ->
      demonitor(elem(from, 0), monitor)
      GenServer.reply(from, {:ok, self()})
    end)

    %{state | phase: :ready, ready_waiters: [], initialize_timer: nil}
  end

  def arm_startup_timeout(state) do
    timer =
      Process.send_after(
        self(),
        :initialize_timeout,
        Keyword.fetch!(state.opts, :startup_timeout)
      )

    %{state | initialize_timer: timer}
  end

  def ingest(state, data, limit_error, consume)
      when is_binary(data) and is_function(consume, 1) do
    buffer = state.buffer <> data
    limit = Keyword.fetch!(state.opts, :max_message_bytes)

    if byte_size(buffer) > limit,
      do: {:error, {limit_error, limit}, state},
      else: consume.(%{state | buffer: buffer})
  end

  def close(%{process: nil}), do: :ok

  def close(%{process: process}) do
    ExternalProcess.close(process)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def request(state, method, params, reply, owner, timeout, limit_error) do
    limit = Keyword.fetch!(state.opts, :max_pending_requests)

    cond do
      timeout == 0 ->
        {:error, :request_expired}

      map_size(state.pending) >= limit ->
        {:error, {limit_error, limit}}

      true ->
        id = state.next_id
        payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

        with :ok <-
               send(state.process.port, payload, Keyword.fetch!(state.opts, :max_message_bytes)) do
          pending = %{
            reply: reply,
            owner: owner,
            monitor: if(owner, do: Process.monitor(owner)),
            timer: start_timer(id, timeout || Keyword.fetch!(state.opts, :request_timeout))
          }

          {:ok, %{state | next_id: id + 1, pending: Map.put(state.pending, id, pending)}}
        end
    end
  end

  def consume_lines(state, handle_line) do
    case :binary.split(state.buffer, "\n") do
      [_rest] ->
        {:ok, state}

      [line, rest] ->
        with {:ok, state} <-
               handle_line.(String.trim_trailing(line, "\r"), %{state | buffer: rest}),
             do: consume_lines(state, handle_line)
    end
  end

  def settle(state, id, message, callback) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:ok, state}

      {entry, pending} ->
        release(entry)
        callback.(entry.reply, message, %{state | pending: pending})
    end
  end

  def release(%{timer: timer, owner: owner, monitor: monitor}) do
    cancel_timer(timer)
    demonitor(owner, monitor)
  end

  def demonitor(nil, _), do: :ok
  def demonitor(_, monitor) when is_reference(monitor), do: Process.demonitor(monitor, [:flush])
  def start_timer(_, :infinity), do: nil
  def start_timer(id, timeout), do: Process.send_after(self(), {:request_timeout, id}, timeout)
  def cancel_timer(nil), do: :ok
  def cancel_timer(timer), do: Process.cancel_timer(timer)

  def fail_waiters(state, reason) do
    Enum.each(state.ready_waiters, fn {from, monitor} ->
      demonitor(elem(from, 0), monitor)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | ready_waiters: [], phase: {:failed, reason}}
  end

  def fail_all(state, reason, reply_error) do
    state = fail_waiters(state, reason)

    Enum.each(state.pending, fn {_id, entry} ->
      release(entry)
      reply_error.(entry.reply, reason)
    end)

    %{state | pending: %{}}
  end

  def deadline(:infinity), do: :infinity

  def deadline(timeout) when is_integer(timeout) and timeout > 0,
    do: System.monotonic_time(:millisecond) + timeout

  def remaining(:infinity), do: :infinity
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  def send(port, payload, max_bytes) do
    data = JSON.encode!(payload) <> "\n"

    cond do
      byte_size(data) > max_bytes -> {:error, {:json_rpc_message_limit, max_bytes}}
      Port.command(port, data, [:nosuspend]) -> :ok
      true -> {:error, :transport_busy}
    end
  rescue
    ArgumentError -> {:error, :transport_closed}
  end
end
