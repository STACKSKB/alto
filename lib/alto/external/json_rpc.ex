defmodule Alto.External.JSONRPC do
  @moduledoc false

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

        with :ok <- send(state.port, payload, Keyword.fetch!(state.opts, :max_message_bytes)) do
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
