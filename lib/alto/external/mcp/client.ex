defmodule Alto.External.MCP.Client do
  @moduledoc """
  A small, supervised MCP stdio client for external local tools.

  The client implements the initialize-capable protocol family used by current
  `fff-mcp` releases. One process is retained per executable/cwd/options tuple,
  so index-backed tools stay warm across Alto runs. It intentionally supports
  tools only; roots, sampling, elicitation, resources, and prompts are refused.
  """

  use GenServer
  alias Alto.External.JSONRPC
  alias Alto.External.Process, as: ExternalProcess

  @protocol_version "2025-11-25"
  @default_timeout 30_000
  @default_max_message_bytes 2_000_000
  @default_max_pending_requests 128
  @default_max_ready_waiters 128

  @type server_options :: keyword()

  @doc "Start or reuse one supervised client for the exact resolved server options."
  @spec ensure_started(server_options()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(opts) when is_list(opts) do
    with {:ok, opts} <- normalize_options(opts) do
      key = client_key(opts)
      name = {:via, Registry, {Alto.External.Registry, key}}
      child = {__MODULE__, Keyword.put(opts, :name, name)}

      case DynamicSupervisor.start_child(Alto.External.Supervisor, child) do
        {:ok, pid} ->
          await_ready(pid, Keyword.fetch!(opts, :startup_timeout))

        {:error, {:already_started, pid}} ->
          await_ready(pid, Keyword.fetch!(opts, :startup_timeout))

        {:error, reason} ->
          {:error, {:mcp_start_failed, reason}}
      end
    end
  catch
    :exit, reason -> {:error, {:mcp_supervisor_unavailable, reason}}
  end

  @doc "List the external server's tools, using its cached catalog after the first call."
  @spec list_tools(pid(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(pid, timeout \\ @default_timeout) do
    GenServer.call(pid, {:list_tools, JSONRPC.deadline(timeout)}, call_timeout(timeout))
  catch
    :exit, reason -> {:error, {:mcp_client_unavailable, reason}}
  end

  @doc "Invoke one external tool with JSON-compatible arguments."
  @spec call_tool(pid(), String.t(), map(), timeout()) ::
          {:ok, term()} | {:error, term()} | {:unknown, term()}
  def call_tool(pid, name, arguments, timeout \\ @default_timeout)
      when is_binary(name) and is_map(arguments) do
    call_timeout = call_timeout(timeout)
    GenServer.call(pid, {:call_tool, name, arguments, JSONRPC.deadline(timeout)}, call_timeout)
  catch
    :exit, {:noproc, _} = reason -> {:error, {:mcp_client_unavailable, reason}}
    :exit, reason -> {:unknown, {:mcp_client_unavailable, reason}}
  end

  @doc "Stop a retained external server. Primarily useful for host shutdown and tests."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid, :normal)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl true
  def format_status(status) do
    # Transport configuration can carry credentials in argv/environment.
    Map.update(status, :state, %{}, fn state ->
      %{phase: state.phase, pending_count: map_size(state.pending)}
    end)
    |> Map.put(:message, :redacted)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      opts: opts,
      port: nil,
      process: nil,
      buffer: "",
      phase: :starting,
      next_id: 1,
      pending: %{},
      ready_waiters: [],
      tools: nil,
      initialize_timer: nil
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    case open_port(state.opts) do
      {:ok, process} ->
        state = %{state | process: process, port: ExternalProcess.port(process)}

        request = %{
          "protocolVersion" => Keyword.fetch!(state.opts, :protocol_version),
          "capabilities" => %{},
          "clientInfo" => %{"name" => "alto", "version" => "0.1.0"}
        }

        case send_request(state, "initialize", request, :initialize, false) do
          {:ok, state} ->
            timer =
              Process.send_after(
                self(),
                :initialize_timeout,
                Keyword.fetch!(state.opts, :startup_timeout)
              )

            {:noreply, %{state | initialize_timer: timer}}

          {:error, reason} ->
            {:stop, reason, fail_all(state, reason)}
        end

      {:error, reason} ->
        {:stop, reason, fail_waiters(state, reason)}
    end
  end

  @impl true
  def handle_call(:await_ready, _from, %{phase: :ready} = state),
    do: {:reply, {:ok, self()}, state}

  def handle_call(:await_ready, _from, %{phase: {:failed, reason}} = state),
    do: {:reply, {:error, reason}, state}

  def handle_call(:await_ready, from, state),
    do: add_ready_waiter(from, state)

  def handle_call({:list_tools, _timeout}, _from, %{phase: :ready, tools: tools} = state)
      when is_list(tools),
      do: {:reply, {:ok, tools}, state}

  def handle_call({:list_tools, deadline}, from, %{phase: :ready} = state) do
    case send_request(
           state,
           "tools/list",
           %{},
           {:list_tools, from},
           true,
           JSONRPC.remaining(deadline)
         ) do
      {:ok, state} -> {:noreply, state}
      {:error, :request_expired} -> {:reply, {:error, :request_expired}, state}
      {:error, {:mcp_pending_request_limit, _} = reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:stop, reason, {:error, reason}, fail_all(state, reason)}
    end
  end

  def handle_call({:call_tool, name, arguments, deadline}, from, %{phase: :ready} = state) do
    params = %{"name" => name, "arguments" => arguments}

    case send_request(
           state,
           "tools/call",
           params,
           {:call_tool, from},
           true,
           JSONRPC.remaining(deadline)
         ) do
      {:ok, state} -> {:noreply, state}
      {:error, :request_expired} -> {:reply, {:error, :request_expired}, state}
      {:error, {:mcp_pending_request_limit, _} = reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:stop, reason, {:error, reason}, fail_all(state, reason)}
    end
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, {:mcp_not_ready, state.phase}}, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data

    if byte_size(buffer) > Keyword.fetch!(state.opts, :max_message_bytes) do
      reason = {:mcp_message_limit, Keyword.fetch!(state.opts, :max_message_bytes)}
      {:stop, reason, fail_all(state, reason)}
    else
      case consume_lines(%{state | buffer: buffer}) do
        {:ok, state} -> {:noreply, state}
        {:error, reason, state} -> {:stop, reason, fail_all(state, reason)}
      end
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = {:mcp_server_exit, status}
    {:stop, reason, fail_all(state, reason)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:stop, {:mcp_server_exit, reason}, fail_all(state, {:mcp_server_exit, reason})}
  end

  def handle_info(:initialize_timeout, %{phase: :starting} = state) do
    reason = {:mcp_startup_timeout, Keyword.fetch!(state.opts, :startup_timeout)}
    {:stop, reason, fail_all(state, reason)}
  end

  def handle_info(:initialize_timeout, state), do: {:noreply, state}

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{reply: reply, owner: owner, monitor: monitor}, pending} ->
        reason = {:mcp_request_timeout, id}
        cancel_request(state, id, "timeout")
        demonitor(owner, monitor)
        reply_error(reply, reason, :unknown)
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case Enum.find(state.pending, fn {_id, entry} ->
           entry.monitor == monitor and entry.owner == owner
         end) do
      {id, %{reply: reply, timer: timer}} ->
        cancel_request(state, id, "owner_disconnected")
        cancel_timer(timer)
        reply_error(reply, {:mcp_request_owner_down, owner}, :unknown)
        {:noreply, %{state | pending: Map.delete(state.pending, id)}}

      nil ->
        case Enum.find(state.ready_waiters, fn {_from, ref} -> ref == monitor end) do
          {from, ^monitor} ->
            GenServer.reply(from, {:error, {:mcp_startup_owner_down, owner}})

            {:noreply,
             %{state | ready_waiters: List.delete(state.ready_waiters, {from, monitor})}}

          nil ->
            {:noreply, state}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{process: process}) when not is_nil(process) do
    ExternalProcess.close(process)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp await_ready(pid, timeout) do
    GenServer.call(pid, :await_ready, call_timeout(timeout))
  catch
    :exit, reason -> {:error, {:mcp_startup_failed, reason}}
  end

  defp normalize_options(opts) do
    defaults = [
      command: nil,
      args: [],
      cwd: File.cwd!(),
      env: %{},
      protocol_version: @protocol_version,
      startup_timeout: @default_timeout,
      request_timeout: @default_timeout,
      max_message_bytes: @default_max_message_bytes,
      max_pending_requests: @default_max_pending_requests,
      max_ready_waiters: @default_max_ready_waiters
    ]

    with {:ok, opts} <- Keyword.validate(opts, defaults),
         command when is_binary(command) and command != "" <- Keyword.get(opts, :command),
         executable when is_binary(executable) <- resolve_executable(command),
         args when is_list(args) <- Keyword.fetch!(opts, :args),
         true <- Enum.all?(args, &is_binary/1),
         cwd when is_binary(cwd) <- Keyword.fetch!(opts, :cwd),
         true <- File.dir?(cwd),
         env when is_map(env) <- Keyword.fetch!(opts, :env),
         :ok <- positive_options(opts) do
      {:ok, Keyword.put(opts, :command, executable)}
    else
      {:error, reason} -> {:error, {:invalid_mcp_options, reason}}
      nil -> {:error, {:mcp_executable_not_found, Keyword.get(opts, :command)}}
      _other -> {:error, {:invalid_mcp_options, opts}}
    end
  end

  defp resolve_executable(command) do
    System.find_executable(command) || if(File.regular?(command), do: Path.expand(command))
  end

  defp positive_options(opts) do
    keys = [
      :startup_timeout,
      :request_timeout,
      :max_message_bytes,
      :max_pending_requests,
      :max_ready_waiters
    ]

    if Enum.all?(keys, fn key ->
         value = Keyword.fetch!(opts, key)
         is_integer(value) and value > 0
       end) do
      :ok
    else
      {:error, :bounds_must_be_positive}
    end
  end

  defp client_key(opts) do
    identity =
      Keyword.take(opts, [
        :command,
        :args,
        :cwd,
        :env,
        :protocol_version,
        :startup_timeout,
        :request_timeout,
        :max_message_bytes,
        :max_pending_requests,
        :max_ready_waiters
      ])

    "mcp:" <>
      Base.url_encode64(:crypto.hash(:sha256, :erlang.term_to_binary(identity)), padding: false)
  end

  defp open_port(opts) do
    command = Keyword.fetch!(opts, :command)
    executable = System.find_executable(command) || if(File.regular?(command), do: command)

    if executable do
      case ExternalProcess.open(executable, Keyword.fetch!(opts, :args),
             cwd: Keyword.fetch!(opts, :cwd),
             env: Keyword.fetch!(opts, :env),
             startup_timeout: Keyword.fetch!(opts, :startup_timeout)
           ) do
        {:ok, _process} = ok -> ok
        {:error, reason} -> {:error, {:mcp_port_open_failed, reason}}
      end
    else
      {:error, {:mcp_executable_not_found, command}}
    end
  rescue
    error in ArgumentError -> {:error, {:mcp_port_open_failed, Exception.message(error)}}
  end

  defp send_request(state, method, params, reply, monitor_owner, timeout \\ nil)
  defp send_request(_state, _method, _params, _reply, _monitor, 0), do: {:error, :request_expired}

  defp send_request(state, method, params, reply, monitor_owner, timeout) do
    if map_size(state.pending) >= Keyword.fetch!(state.opts, :max_pending_requests) do
      {:error, {:mcp_pending_request_limit, Keyword.fetch!(state.opts, :max_pending_requests)}}
    else
      id = state.next_id

      payload =
        %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

      case JSONRPC.send(state.port, payload, Keyword.fetch!(state.opts, :max_message_bytes)) do
        :ok ->
          timer =
            start_timer(id, timeout || Keyword.fetch!(state.opts, :request_timeout))

          {owner, monitor} = owner_monitor(reply, monitor_owner)

          pending =
            Map.put(state.pending, id, %{
              reply: reply,
              timer: timer,
              owner: owner,
              monitor: monitor
            })

          {:ok, %{state | next_id: id + 1, pending: pending}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp send_notification(state, method) do
    payload = JSON.encode!(%{"jsonrpc" => "2.0", "method" => method})

    case port_command(state.port, payload <> "\n") do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp port_command(port, payload) do
    if Port.command(port, payload, [:nosuspend]),
      do: :ok,
      else: {:error, {:mcp_transport_lost, :closed}}
  rescue
    ArgumentError -> {:error, {:mcp_transport_lost, :closed}}
  end

  defp consume_lines(state) do
    case :binary.split(state.buffer, "\n") do
      [rest] ->
        {:ok, %{state | buffer: rest}}

      [line, rest] ->
        with {:ok, state} <-
               handle_line(String.trim_trailing(line, "\r"), %{state | buffer: rest}) do
          consume_lines(state)
        end
    end
  end

  defp handle_line("", state), do: {:ok, state}

  defp handle_line(line, state) do
    case JSON.decode(line) do
      {:ok, message} when is_map(message) -> handle_message(message, state)
      {:ok, _other} -> {:error, :mcp_message_not_object, state}
      {:error, error} -> {:error, {:mcp_invalid_json, Exception.message(error)}, state}
    end
  end

  # A server request has both `method` and `id`; inspect that shape before
  # looking up pending responses so it cannot consume an outgoing id.
  defp handle_message(%{"method" => _method, "id" => _id} = message, state) do
    maybe_refuse_server_request(message, state)
  end

  defp handle_message(%{"id" => id} = message, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:ok, state}

      {%{reply: reply, timer: timer, owner: owner, monitor: monitor}, pending} ->
        cancel_timer(timer)
        demonitor(owner, monitor)
        settle_response(reply, message, %{state | pending: pending})
    end
  end

  defp handle_message(_notification, state), do: {:ok, state}

  defp settle_response(:initialize, %{"result" => result}, state) when is_map(result) do
    expected = Keyword.fetch!(state.opts, :protocol_version)

    if result["protocolVersion"] == expected do
      if state.initialize_timer, do: cancel_timer(state.initialize_timer)

      case send_notification(state, "notifications/initialized") do
        {:ok, state} ->
          Enum.each(state.ready_waiters, fn {from, monitor} ->
            demonitor(elem(from, 0), monitor)
            GenServer.reply(from, {:ok, self()})
          end)

          {:ok, %{state | phase: :ready, ready_waiters: [], initialize_timer: nil}}

        {:error, reason} ->
          {:error, reason, fail_waiters(state, reason)}
      end
    else
      reason = {:mcp_initialize_protocol_mismatch, expected, result["protocolVersion"]}
      {:error, {:mcp_initialize_failed, reason}, fail_waiters(state, reason)}
    end
  end

  defp settle_response(:initialize, message, state) do
    reason = response_error(message)
    {:error, {:mcp_initialize_failed, reason}, fail_waiters(state, reason)}
  end

  defp settle_response({:list_tools, from}, %{"result" => %{"tools" => tools}}, state)
       when is_list(tools) do
    GenServer.reply(from, {:ok, tools})
    {:ok, %{state | tools: tools}}
  end

  defp settle_response({:call_tool, from}, %{"result" => result}, state) do
    GenServer.reply(from, normalize_tool_result(result))
    {:ok, state}
  end

  defp settle_response({_kind, from}, message, state) do
    GenServer.reply(from, {:error, {:mcp_error, response_error(message)}})
    {:ok, state}
  end

  defp normalize_tool_result(%{"isError" => true} = result),
    do: {:error, {:mcp_tool_error, result}}

  defp normalize_tool_result(result), do: {:ok, result}

  defp response_error(%{"error" => error}), do: error
  defp response_error(message), do: {:invalid_mcp_response, message}

  defp maybe_refuse_server_request(%{"method" => _method, "id" => id}, state) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Alto MCP client supports tools only"}
    }

    _ = port_command(state.port, JSON.encode!(response) <> "\n")
    {:ok, state}
  end

  defp maybe_refuse_server_request(_message, state), do: {:ok, state}

  defp fail_waiters(state, reason) do
    Enum.each(state.ready_waiters, fn {from, monitor} ->
      demonitor(elem(from, 0), monitor)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | ready_waiters: [], phase: {:failed, reason}}
  end

  defp fail_all(state, reason) do
    state
    |> fail_waiters(reason)
    |> then(fn state ->
      Enum.each(state.pending, fn {_id,
                                   %{reply: reply, timer: timer, owner: owner, monitor: monitor}} ->
        cancel_timer(timer)
        demonitor(owner, monitor)
        reply_error(reply, reason, classify_failure(reply))
      end)

      %{state | pending: %{}}
    end)
  end

  defp add_ready_waiter(from, state) do
    if length(state.ready_waiters) >= Keyword.fetch!(state.opts, :max_ready_waiters) do
      {:reply,
       {:error, {:mcp_ready_waiter_limit, Keyword.fetch!(state.opts, :max_ready_waiters)}}, state}
    else
      owner = elem(from, 0)
      monitor = Process.monitor(owner)
      {:noreply, %{state | ready_waiters: [{from, monitor} | state.ready_waiters]}}
    end
  end

  defp owner_monitor(_reply, false), do: {nil, nil}
  defp owner_monitor({_kind, from}, true), do: {elem(from, 0), Process.monitor(elem(from, 0))}

  defp demonitor(nil, _monitor), do: :ok

  defp demonitor(_owner, monitor) when is_reference(monitor),
    do: Process.demonitor(monitor, [:flush])

  defp start_timer(_id, :infinity), do: nil
  defp start_timer(id, timeout), do: Process.send_after(self(), {:request_timeout, id}, timeout)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp cancel_request(state, id, reason) do
    payload =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => id, "reason" => reason}
      })

    _ = port_command(state.port, payload <> "\n")
    :ok
  end

  defp classify_failure({:call_tool, _from}), do: :unknown
  defp classify_failure(_reply), do: :error

  defp reply_error(:initialize, _reason, _class), do: :ok

  defp reply_error({:call_tool, from}, reason, :unknown),
    do: GenServer.reply(from, {:unknown, reason})

  defp reply_error({_kind, from}, reason, _class), do: GenServer.reply(from, {:error, reason})

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout + 100
  defp call_timeout(_timeout), do: @default_timeout
end
