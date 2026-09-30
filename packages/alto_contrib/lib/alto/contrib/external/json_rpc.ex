defmodule Alto.Contrib.External.JSONRPC do
  @moduledoc "Shared JSON-RPC process lifecycle; client modules own protocol callbacks."
  use GenServer

  alias Alto.Contrib.External.Process, as: ExternalProcess

  @transport_options [
    args: [type: {:list, :string}, default: []],
    cwd: [type: :string],
    env: [type: {:map, :any, :any}, default: %{}],
    executor: [type: :any, default: {Alto.Contrib.Command.Executors.Unsandboxed, []}],
    startup_timeout: [type: :pos_integer, default: 30_000],
    max_pending_requests: [type: :pos_integer, default: 128],
    max_ready_waiters: [type: :pos_integer, default: 128]
  ]

  def normalize_options(opts, schema) do
    schema = Keyword.merge(@transport_options, schema)
    opts = Keyword.put_new(opts, :cwd, File.cwd!())

    with {:ok, opts} <- NimbleOptions.validate(opts, schema),
         true <- opts[:command] != "" or {:error, :empty_external_command},
         true <- File.dir?(opts[:cwd]) or {:error, {:invalid_working_directory, opts[:cwd]}},
         executable when is_binary(executable) <-
           ExternalProcess.resolve_executable(opts[:command]) ||
             {:error, {:external_executable_not_found, opts[:command]}} do
      {:ok, Keyword.put(opts, :command, executable)}
    else
      {:error, _} = error -> error
    end
  end

  @impl true
  def init({protocol, opts}) do
    Process.flag(:trap_exit, true)

    state =
      Map.merge(
        %{
          owner: if(opts[:owner], do: Process.monitor(opts[:owner])),
          protocol: protocol,
          opts: opts,
          process: nil,
          phase: :starting,
          next_id: 1,
          pending: %{},
          ready_waiters: [],
          initialize_timer: nil
        },
        protocol.initial_state(opts)
      )

    {:ok, state, {:continue, :open}}
  end

  def start_link(module, opts),
    do: GenServer.start_link(__MODULE__, {module, opts}, name: Keyword.get(opts, :name))

  def child_spec(module, opts) do
    %{
      id: {module, Keyword.get(opts, :name)},
      start: {__MODULE__, :start_link, [module, opts]},
      restart: :temporary
    }
  end

  def ensure_started(module, opts, schema) do
    with {:ok, opts} <- normalize_options(opts, schema) do
      # Keyword lookup uses the first occurrence; option order is not client identity.
      identity = opts |> Enum.reverse() |> Map.new() |> :erlang.term_to_binary([:deterministic])
      key = {module, :crypto.hash(:sha256, identity)}
      name = {:via, Registry, {Alto.Contrib.External.Registry, key}}
      child = child_spec(module, Keyword.put(opts, :name, name))

      case DynamicSupervisor.start_child(Alto.Contrib.External.Supervisor, child) do
        {:ok, pid} ->
          await_startup(pid, opts, module)

        {:error, {:already_started, pid}} ->
          await_startup(pid, opts, module)

        {:error, reason} ->
          {:error, {:external_client_failed, module, :start, reason}}
      end
    end
  catch
    :exit, reason -> {:error, {:external_client_failed, module, :supervisor, reason}}
  end

  defp await_startup(pid, opts, module) do
    GenServer.call(pid, :await_ready, call_timeout(Keyword.fetch!(opts, :startup_timeout)))
  catch
    :exit, reason -> {:error, {:external_client_failed, module, :ready, reason}}
  end

  def call(client, message, timeout \\ 5_000, failure_class \\ :error) do
    GenServer.call(client, message, timeout)
  catch
    :exit, {:noproc, _} = reason -> {:error, {:json_rpc_client_unavailable, reason}}
    :exit, reason -> {failure_class, {:json_rpc_client_unavailable, reason}}
  end

  def call_timeout(:infinity), do: :infinity
  def call_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout + 100

  @impl true
  def handle_continue(:open, %{protocol: protocol} = state) do
    case open_process(state.opts) do
      {:ok, process} ->
        state = %{state | process: process}

        case request(state, "initialize", protocol.initialize(state), nil, nil, :error) do
          {:ok, state} -> {:noreply, arm_startup_timeout(state)}
          {:error, reason} -> {:stop, reason, fail_all(state, reason)}
        end

      {:error, reason} ->
        {:stop, reason, fail_all(state, reason)}
    end
  end

  defp open_process(opts) do
    invocation = %{
      requested_program: opts[:command],
      executable: opts[:command],
      args: opts[:args],
      cwd: opts[:cwd],
      timeout_ms: 30_000,
      max_output_bytes: Alto.Contrib.Command.default_output_bytes()
    }

    {executor, executor_opts} = opts[:executor]

    with {:ok, execution, details} when is_map(details) <-
           executor.prepare(invocation, executor_opts) do
      Alto.Contrib.Command.open(%{executor: executor, execution: execution},
        env: opts[:env],
        line: opts[:max_message_bytes],
        startup_timeout: opts[:startup_timeout]
      )
    end
  rescue
    error in ArgumentError -> {:error, {:json_rpc_process_open_failed, Exception.message(error)}}
  end

  @impl true
  def format_status(status) do
    Map.update(status, :state, %{}, fn state ->
      %{phase: state.phase, pending_count: map_size(state.pending)}
    end)
    |> Map.put(:message, :redacted)
  end

  @impl true
  def handle_call(:await_ready, _from, %{phase: :ready} = state),
    do: {:reply, {:ok, self()}, state}

  def handle_call(:await_ready, _from, %{phase: {:failed, reason}} = state),
    do: {:reply, {:error, reason}, state}

  def handle_call(:await_ready, from, state) do
    limit = Keyword.fetch!(state.opts, :max_ready_waiters)

    if length(state.ready_waiters) >= limit do
      {:reply, {:error, {:json_rpc_ready_waiter_limit, limit}}, state}
    else
      monitor = Process.monitor(elem(from, 0))
      {:noreply, %{state | ready_waiters: [{from, monitor} | state.ready_waiters]}}
    end
  end

  def handle_call(message, from, state), do: state.protocol.handle_call(message, from, state)

  def ready(state), do: finish_startup(state, :ready, {:ok, self()})

  defp finish_startup(state, phase, reply) do
    cancel_timer(state.initialize_timer)

    Enum.each(state.ready_waiters, fn {from, monitor} ->
      demonitor(elem(from, 0), monitor)
      GenServer.reply(from, reply)
    end)

    %{state | phase: phase, ready_waiters: [], initialize_timer: nil}
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

  @impl true
  def handle_info({:request_timeout, id}, state) do
    {entry, state} = take_pending(state, id)

    if entry do
      state.protocol.cancel_request(state, id, "timeout")
      reply_failure(entry, {:json_rpc_request_timeout, id})
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, owner, _}, state) do
    state = drop_owner(state, ref, owner)

    state =
      if function_exported?(state.protocol, :owner_down, 2),
        do: state.protocol.owner_down(state, ref),
        else: state

    {:noreply, state}
  end

  def handle_info(message, state) do
    case transport_event(message, state, &handle_message/2) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:stop, reason, fail_all(state, reason)}
    end
  end

  defp transport_event({port, {:data, {:eol, line}}}, %{process: %{port: port}} = state, handler),
    do: decode_line(String.trim_trailing(line, "\r"), state, handler)

  defp transport_event({port, {:data, {:noeol, _}}}, %{process: %{port: port}} = state, _),
    do:
      {:error, {:json_rpc_incomplete_line, Keyword.fetch!(state.opts, :max_message_bytes)}, state}

  defp transport_event({port, {:data, _}}, %{process: %{port: port}} = state, _),
    do: {:error, :json_rpc_unframed_data, state}

  defp transport_event({port, {:exit_status, status}}, %{process: %{port: port}} = state, _),
    do: {:error, {:json_rpc_process_exit, status}, state}

  defp transport_event({:EXIT, port, reason}, %{process: %{port: port}} = state, _),
    do: {:error, {:json_rpc_process_exit, reason}, state}

  defp transport_event(:initialize_timeout, %{phase: :starting} = state, _),
    do: {:error, {:json_rpc_startup_timeout, Keyword.fetch!(state.opts, :startup_timeout)}, state}

  defp transport_event(_, state, _), do: {:ok, state}

  @impl true
  def terminate(_reason, %{process: nil}), do: :ok
  def terminate(_reason, %{process: process}), do: ExternalProcess.close(process)

  def handle_request(state, method, params, from, deadline, failure_class \\ :error) do
    case request(state, method, params, from, remaining(deadline), failure_class) do
      {:ok, state} -> {:noreply, state}
      {:error, :request_expired} -> {:reply, {:error, :request_expired}, state}
      {:error, {:json_rpc_pending_request_limit, _} = reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:stop, reason, {:error, reason}, fail_all(state, reason)}
    end
  end

  defp request(state, method, params, from, timeout, failure_class) do
    owner = if from, do: elem(from, 0)
    limit = Keyword.fetch!(state.opts, :max_pending_requests)

    cond do
      timeout == 0 ->
        {:error, :request_expired}

      map_size(state.pending) >= limit ->
        {:error, {:json_rpc_pending_request_limit, limit}}

      true ->
        id = state.next_id
        payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

        with :ok <-
               send_payload(state, payload) do
          pending = %{
            from: from,
            method: method,
            failure_class: failure_class,
            owner: owner,
            monitor: if(owner, do: Process.monitor(owner)),
            timer: start_timer(id, timeout || Keyword.fetch!(state.opts, :request_timeout))
          }

          {:ok, %{state | next_id: id + 1, pending: Map.put(state.pending, id, pending)}}
        end
    end
  end

  defp decode_line("", state, _handle_message), do: {:ok, state}

  defp decode_line(line, state, handle_message) do
    case JSON.decode(line) do
      {:ok, message} when is_map(message) ->
        handle_message.(message, state)

      {:ok, _other} ->
        {:error, :json_rpc_message_not_object, state}

      {:error, _error} ->
        {:error, {:json_rpc_invalid_json, "Malformed JSON-RPC message."}, state}
    end
  end

  # Server requests may share an outgoing id; only method-free messages settle requests.
  defp handle_message(%{"method" => _} = message, state),
    do: state.protocol.handle_message(message, state)

  defp handle_message(%{"id" => id} = message, state) do
    case take_pending(state, id) do
      {nil, state} ->
        {:ok, state}

      {%{from: nil}, state} ->
        with %{"result" => result} when is_map(result) <- message,
             {:ok, state} <- state.protocol.initialized(result, state) do
          {:ok, ready(state)}
        else
          {:error, reason} -> {:error, reason, state}
          other -> {:error, {:json_rpc_initialize_failed, response_error(other)}, state}
        end

      {%{from: from, method: method}, state} ->
        {reply, state} =
          case message do
            %{"result" => result} -> state.protocol.result(method, result, state)
            _ -> {{:error, {:json_rpc_error, method, response_error(message)}}, state}
          end

        GenServer.reply(from, reply)
        {:ok, state}
    end
  end

  defp handle_message(_message, state), do: {:ok, state}
  defp response_error(%{"error" => error}), do: error
  defp response_error(message), do: {:invalid_json_rpc_response, message}

  defp take_pending(state, id) do
    {entry, pending} = Map.pop(state.pending, id)
    if entry, do: release(entry)
    {entry, %{state | pending: pending}}
  end

  defp drop_owner(state, monitor, owner) do
    {owned, pending} =
      Enum.split_with(state.pending, fn {_id, entry} ->
        entry.monitor == monitor and entry.owner == owner
      end)

    Enum.each(owned, fn {id, entry} ->
      state.protocol.cancel_request(state, id, "owner_disconnected")
      release(entry)
    end)

    %{
      state
      | pending: Map.new(pending),
        ready_waiters: Enum.reject(state.ready_waiters, fn {_from, ref} -> ref == monitor end)
    }
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

  defp fail_all(state, reason) do
    state = finish_startup(state, {:failed, reason}, {:error, reason})

    Enum.each(state.pending, fn {_id, entry} ->
      release(entry)
      reply_failure(entry, reason)
    end)

    %{state | pending: %{}}
  end

  defp reply_failure(%{from: nil}, _reason), do: :ok

  defp reply_failure(%{from: from, failure_class: class}, reason),
    do: GenServer.reply(from, {class, reason})

  def deadline(:infinity), do: :infinity

  def deadline(timeout) when is_integer(timeout) and timeout > 0,
    do: System.monotonic_time(:millisecond) + timeout

  def remaining(:infinity), do: :infinity
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  def notify(state, method, params \\ %{}),
    do: send_payload(state, %{"jsonrpc" => "2.0", "method" => method, "params" => params})

  def send_payload(state, payload) do
    max_bytes = Keyword.fetch!(state.opts, :max_message_bytes)
    data = JSON.encode!(payload)

    cond do
      byte_size(data) > max_bytes -> {:error, {:json_rpc_message_limit, max_bytes}}
      Port.command(state.process.port, [data, "\n"], [:nosuspend]) -> :ok
      true -> {:error, :transport_busy}
    end
  rescue
    ArgumentError -> {:error, :transport_closed}
  end
end
