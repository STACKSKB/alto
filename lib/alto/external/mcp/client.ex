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
      JSONRPC.ensure_started(__MODULE__, opts)
    end
  end

  @doc "List the external server's tools, using its cached catalog after the first call."
  @spec list_tools(pid(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(pid, timeout \\ @default_timeout) do
    GenServer.call(pid, {:list_tools, JSONRPC.deadline(timeout)}, JSONRPC.call_timeout(timeout))
  catch
    :exit, reason -> {:error, {:mcp_client_unavailable, reason}}
  end

  @doc "Invoke one external tool with JSON-compatible arguments."
  @spec call_tool(pid(), String.t(), map(), timeout()) ::
          {:ok, term()} | {:error, term()} | {:unknown, term()}
  def call_tool(pid, name, arguments, timeout \\ @default_timeout)
      when is_binary(name) and is_map(arguments) do
    GenServer.call(
      pid,
      {:call_tool, name, arguments, JSONRPC.deadline(timeout)},
      JSONRPC.call_timeout(timeout)
    )
  catch
    :exit, {:noproc, _} = reason -> {:error, {:mcp_client_unavailable, reason}}
    :exit, reason -> {:unknown, {:mcp_client_unavailable, reason}}
  end

  @doc "Stop a retained external server. Primarily useful for host shutdown and tests."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid, :normal)

  def start_link(opts), do: JSONRPC.start_link(__MODULE__, opts)

  @doc false
  def child_spec(opts) do
    JSONRPC.child_spec(__MODULE__, opts)
  end

  @impl true
  def format_status(status), do: JSONRPC.format_status(status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, JSONRPC.state(opts, %{tools: nil}), {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    request = %{
      "protocolVersion" => Keyword.fetch!(state.opts, :protocol_version),
      "capabilities" => %{},
      "clientInfo" => %{"name" => "alto", "version" => "0.1.0"}
    }

    case JSONRPC.open(
           state,
           &open_port/1,
           &send_request(&1, "initialize", request, :initialize, false)
         ) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:stop, reason, fail_all(state, reason)}
    end
  end

  @impl true
  def handle_call(:await_ready, from, state),
    do: JSONRPC.await_ready(state, from, :mcp_ready_waiter_limit)

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
  def handle_info({port, {:data, data}}, %{process: %{port: port}} = state) do
    case JSONRPC.ingest(state, data, :mcp_message_limit, &consume_lines/1) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:stop, reason, fail_all(state, reason)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{process: %{port: port}} = state) do
    reason = {:mcp_server_exit, status}
    {:stop, reason, fail_all(state, reason)}
  end

  def handle_info({:EXIT, port, reason}, %{process: %{port: port}} = state) do
    {:stop, {:mcp_server_exit, reason}, fail_all(state, {:mcp_server_exit, reason})}
  end

  def handle_info(:initialize_timeout, %{phase: :starting} = state) do
    reason = {:mcp_startup_timeout, Keyword.fetch!(state.opts, :startup_timeout)}
    {:stop, reason, fail_all(state, reason)}
  end

  def handle_info(:initialize_timeout, state), do: {:noreply, state}

  def handle_info({:request_timeout, id}, state) do
    JSONRPC.expire(state, id, fn reply ->
      cancel_request(state, id, "timeout")
      reply_error(reply, {:mcp_request_timeout, id}, :unknown)
    end)
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    {:noreply,
     JSONRPC.drop_owner(state, monitor, owner, &cancel_request(state, &1, "owner_disconnected"))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: JSONRPC.close(state)

  @options_schema [
    command: [type: :string, required: true],
    args: [type: {:list, :string}, default: []],
    cwd: [type: :string],
    env: [type: {:map, :any, :any}, default: %{}],
    executor: [type: :any, default: Alto.Command.Executors.Unsandboxed],
    protocol_version: [type: :any, default: @protocol_version],
    startup_timeout: [type: :pos_integer, default: @default_timeout],
    request_timeout: [type: :pos_integer, default: @default_timeout],
    max_message_bytes: [type: :pos_integer, default: @default_max_message_bytes],
    max_pending_requests: [type: :pos_integer, default: @default_max_pending_requests],
    max_ready_waiters: [type: :pos_integer, default: @default_max_ready_waiters]
  ]

  defp normalize_options(opts), do: JSONRPC.normalize_options(opts, @options_schema)

  defp open_port(opts) do
    context = %Alto.Tool.Context{session_id: "mcp", cwd: Keyword.fetch!(opts, :cwd)}

    result =
      with {:ok, prepared} <-
             Alto.Command.prepare(
               %{
                 "program" => Keyword.fetch!(opts, :command),
                 "args" => Keyword.fetch!(opts, :args)
               },
               context,
               executor: Keyword.fetch!(opts, :executor)
             ) do
        Alto.Command.open(prepared,
          env: Keyword.fetch!(opts, :env),
          startup_timeout: Keyword.fetch!(opts, :startup_timeout)
        )
      end

    case result do
      {:ok, _process} = ok -> ok
      {:error, reason} -> {:error, {:mcp_port_open_failed, reason}}
    end
  rescue
    error in ArgumentError -> {:error, {:mcp_port_open_failed, Exception.message(error)}}
  end

  defp send_request(state, method, params, reply, monitor_owner, timeout \\ nil) do
    owner = if monitor_owner, do: elem(elem(reply, 1), 0), else: nil
    JSONRPC.request(state, method, params, reply, owner, timeout, :mcp_pending_request_limit)
  end

  defp send_notification(state, method) do
    with :ok <- send_payload(state, %{"jsonrpc" => "2.0", "method" => method}),
         do: {:ok, state}
  end

  defp send_payload(state, payload),
    do: JSONRPC.send(state.process.port, payload, Keyword.fetch!(state.opts, :max_message_bytes))

  defp consume_lines(state), do: JSONRPC.consume_lines(state, &handle_message/2)

  # A server request has both `method` and `id`; inspect that shape before
  # looking up pending responses so it cannot consume an outgoing id.
  defp handle_message(%{"method" => _method, "id" => _id} = message, state) do
    maybe_refuse_server_request(message, state)
  end

  defp handle_message(%{"id" => id} = message, state),
    do: JSONRPC.settle(state, id, message, &settle_response/3)

  defp handle_message(_notification, state), do: {:ok, state}

  defp settle_response(:initialize, %{"result" => result}, state) when is_map(result) do
    expected = Keyword.fetch!(state.opts, :protocol_version)

    if result["protocolVersion"] == expected do
      case send_notification(state, "notifications/initialized") do
        {:ok, state} ->
          {:ok, JSONRPC.ready(state)}

        {:error, reason} ->
          {:error, reason, JSONRPC.fail_waiters(state, reason)}
      end
    else
      reason = {:mcp_initialize_protocol_mismatch, expected, result["protocolVersion"]}
      {:error, {:mcp_initialize_failed, reason}, JSONRPC.fail_waiters(state, reason)}
    end
  end

  defp settle_response(:initialize, message, state) do
    reason = response_error(message)
    {:error, {:mcp_initialize_failed, reason}, JSONRPC.fail_waiters(state, reason)}
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

    _ = send_payload(state, response)
    {:ok, state}
  end

  defp maybe_refuse_server_request(_message, state), do: {:ok, state}

  defp fail_all(state, reason),
    do:
      JSONRPC.fail_all(state, reason, fn reply, reason ->
        reply_error(reply, reason, classify_failure(reply))
      end)

  defp cancel_request(state, id, reason) do
    _ =
      send_payload(state, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => id, "reason" => reason}
      })

    :ok
  end

  defp classify_failure({:call_tool, _from}), do: :unknown
  defp classify_failure(_reply), do: :error

  defp reply_error(:initialize, _reason, _class), do: :ok

  defp reply_error({:call_tool, from}, reason, :unknown),
    do: GenServer.reply(from, {:unknown, reason})

  defp reply_error({_kind, from}, reason, _class), do: GenServer.reply(from, {:error, reason})
end
