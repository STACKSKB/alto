defmodule Alto.Contrib.Socket.Client do
  @moduledoc """
  A bounded client for Alto's v1 Unix socket NDJSON protocol.

  The returned struct is an immutable handle; the socket is owned by the
  private GenServer behind it.  Replies are correlated by envelope id, so
  notifications can arrive between a request and its reply.  Notifications
  are retained for `next/2` and consumed by the caller on demand.
  """

  use GenServer

  @default_timeout 5_000
  @bounds [
    max_line_bytes: 1_048_576,
    max_pending: 100,
    max_events: 1_000,
    max_event_bytes: 8_000_000
  ]

  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}

  @doc "Connect to a local Unix socket."
  @spec connect(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(path, opts \\ [])

  def connect(path, opts) when is_binary(path) do
    GenServer.start(__MODULE__, {path, opts, Keyword.get(opts, :owner, self())})
    |> case do
      {:ok, pid} -> {:ok, %__MODULE__{pid: pid}}
      other -> other
    end
  end

  def connect(_path, _opts), do: {:error, :invalid_path}

  @doc "Send a command map and wait for its correlated reply."
  @spec request(t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(client, command, opts \\ [])

  def request(%__MODULE__{pid: pid}, command, opts) when is_map(command) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    call(pid, {:request, command, timeout}, timeout)
  end

  def request(pid, command, opts) when is_pid(pid) and is_map(command),
    do: request(%__MODULE__{pid: pid}, command, opts)

  def request(_client, _command, _opts), do: {:error, :invalid_command}

  @doc "Return the next retained asynchronous envelope, waiting up to timeout."
  @spec next(t(), timeout()) :: {:ok, map()} | {:error, term()}
  def next(client, timeout \\ @default_timeout)

  def next(%__MODULE__{pid: pid}, timeout), do: call(pid, {:next, timeout}, timeout)

  def next(pid, timeout) when is_pid(pid), do: next(%__MODULE__{pid: pid}, timeout)

  defp call(pid, message, timeout) do
    if valid_timeout?(timeout),
      do: GenServer.call(pid, message, timeout + 100),
      else: {:error, :invalid_timeout}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :closed}
  end

  @doc "Close the client socket."
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal), else: :ok
  catch
    :exit, _ -> :ok
  end

  def close(pid) when is_pid(pid), do: close(%__MODULE__{pid: pid})

  @impl true
  def init({path, opts, owner}) do
    bounds = Map.new(@bounds, fn {key, default} -> {key, Keyword.get(opts, key, default)} end)
    timeout = Keyword.get(opts, :connect_timeout, @default_timeout)

    with true <- is_pid(owner),
         true <- Enum.all?(Map.values(bounds), &valid_bound?/1) and valid_timeout?(timeout),
         {:ok, socket} <-
           :gen_tcp.connect(
             {:local, path},
             0,
             [
               :binary,
               active: false,
               packet: :line,
               packet_size: bounds.max_line_bytes + 1,
               buffer: bounds.max_line_bytes + 1
             ],
             timeout
           ) do
      :ok = :inet.setopts(socket, active: :once)

      {:ok,
       Map.merge(bounds, %{
         socket: socket,
         owner_ref: Process.monitor(owner),
         event_bytes: 0,
         closed: nil,
         events: :queue.new(),
         event_count: 0,
         waiters: :queue.new(),
         pending: %{},
         next_id: 1
       })}
    else
      false -> {:stop, :invalid_bounds}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(_request, _from, %{closed: reason} = state) when not is_nil(reason),
    do: {:reply, {:error, reason}, state}

  def handle_call({:request, command, timeout}, from, state) do
    if map_size(state.pending) >= state.max_pending do
      {:reply, {:error, :too_many_pending}, state}
    else
      id = "c-#{state.next_id}"

      case encode_command(command, id, state.max_line_bytes) do
        {:error, reason} ->
          {:reply, {:error, reason}, state}

        {:ok, line} ->
          send_request(line, id, from, timeout, state)
      end
    end
  end

  def handle_call({:next, timeout}, from, state) do
    case :queue.out(state.events) do
      {{:value, {event, bytes}}, events} ->
        {:reply, {:ok, event},
         %{
           state
           | events: events,
             event_count: state.event_count - 1,
             event_bytes: state.event_bytes - bytes
         }}

      {:empty, _} ->
        if timeout == 0 do
          {:reply, {:error, :timeout}, state}
        else
          if :queue.len(state.waiters) >= state.max_pending do
            {:reply, {:error, :too_many_waiters}, state}
          else
            timer = Process.send_after(self(), {:next_timeout, from}, timeout)
            {:noreply, %{state | waiters: :queue.in({from, timer}, state.waiters)}}
          end
        end
    end
  end

  defp send_request(line, id, from, timeout, state) do
    case :gen_tcp.send(state.socket, line) do
      :ok ->
        timer = Process.send_after(self(), {:request_timeout, id}, timeout)
        pending = Map.put(state.pending, id, {from, timer})
        {:noreply, %{state | pending: pending, next_id: state.next_id + 1}}

      {:error, reason} ->
        {:reply, {:error, {:send, reason}}, state}
    end
  end

  @impl true
  def handle_info({:tcp, _, _}, %{closed: reason} = state) when not is_nil(reason),
    do: {:noreply, state}

  def handle_info({:tcp, socket, line}, %{socket: socket} = state) do
    # Line mode can return a bounded fragment for an oversized line.
    result =
      if byte_size(line) <= state.max_line_bytes + 1 and String.ends_with?(line, "\n"),
        do: handle_line(line |> String.trim_trailing("\n") |> String.trim_trailing("\r"), state),
        else: {:error, :line_too_large}

    case result do
      {:ok, next} ->
        :inet.setopts(socket, active: :once)
        {:noreply, next}

      {:error, reason} ->
        {:noreply, close_state(state, reason)}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:noreply, close_state(state, :closed)}

  def handle_info({:tcp_error, socket, :emsgsize}, %{socket: socket} = state),
    do: {:noreply, close_state(state, :line_too_large)}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: {:noreply, close_state(state, {:socket, reason})}

  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:request_timeout, id}, state),
    do: {:noreply, finish_request(state, id, {:error, :timeout})}

  def handle_info({:next_timeout, from}, state) do
    {found, waiters} = remove_waiter(state.waiters, from)
    if found, do: GenServer.reply(from, {:error, :timeout})
    {:noreply, %{state | waiters: waiters}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_state(state, :closed)
    :ok
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  defp close_state(%{closed: reason} = state, _) when not is_nil(reason), do: state

  defp close_state(state, reason) do
    :gen_tcp.close(state.socket)

    Enum.each(Map.values(state.pending) ++ :queue.to_list(state.waiters), fn waiter ->
      reply(waiter, {:error, reason})
    end)

    %{
      state
      | closed: reason,
        pending: %{},
        waiters: :queue.new(),
        events: :queue.new(),
        event_count: 0,
        event_bytes: 0
    }
  end

  defp handle_line(<<>>, state), do: {:ok, state}

  defp handle_line(line, state) do
    case JSON.decode(line) do
      {:ok, %{"v" => 1, "type" => type, "id" => id} = envelope}
      when is_binary(type) and is_binary(id) ->
        case Map.get(envelope, "type") do
          type when type in ["ok", "error"] -> {:ok, handle_reply(envelope, state)}
          _ -> enqueue_event(envelope, state)
        end

      _ ->
        {:error, :invalid_envelope}
    end
  end

  defp handle_reply(envelope, state) do
    result =
      if envelope["type"] == "ok",
        do: {:ok, envelope},
        else: {:error, {:server, envelope["code"], envelope["detail"]}}

    finish_request(state, envelope["id"], result)
  end

  defp finish_request(state, id, result) do
    {waiter, pending} = Map.pop(state.pending, id)
    if waiter, do: reply(waiter, result)
    %{state | pending: pending}
  end

  defp reply({from, timer}, result) do
    Process.cancel_timer(timer)
    GenServer.reply(from, result)
  end

  defp enqueue_event(event, state) do
    bytes = :erlang.external_size(event)

    case :queue.out(state.waiters) do
      {{:value, waiter}, waiters} ->
        reply(waiter, {:ok, event})
        {:ok, %{state | waiters: waiters}}

      {:empty, _}
      when state.event_count < state.max_events and
             state.event_bytes + bytes <= state.max_event_bytes ->
        {:ok,
         %{
           state
           | events: :queue.in({event, bytes}, state.events),
             event_count: state.event_count + 1,
             event_bytes: state.event_bytes + bytes
         }}

      {:empty, _} ->
        {:error, :event_buffer_overflow}
    end
  end

  defp encode_command(command, id, max) do
    line = command |> stringify_keys() |> Map.merge(%{"v" => 1, "id" => id}) |> JSON.encode!()
    line = line <> "\n"
    if byte_size(line) <= max, do: {:ok, line}, else: {:error, :overflow}
  rescue
    _ -> {:error, :invalid_command}
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {stringify_key(k), v} end)
  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key) when is_integer(key), do: Integer.to_string(key)
  defp stringify_key(_key), do: raise(ArgumentError, "invalid map key")
  defp valid_bound?(value), do: is_integer(value) and value > 0
  defp valid_timeout?(value), do: is_integer(value) and value in 0..4_294_967_295

  defp remove_waiter(queue, from) do
    case List.keytake(:queue.to_list(queue), from, 0) do
      {_, remaining} -> {true, :queue.from_list(remaining)}
      nil -> {false, queue}
    end
  end
end
