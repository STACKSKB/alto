defmodule Alto.External.MCP.Client do
  @moduledoc """
  A small, supervised MCP stdio client for external local tools.

  The client implements the initialize-capable protocol family used by current
  `fff-mcp` releases. One process is retained per executable/cwd/options tuple,
  so index-backed tools stay warm across Alto runs. It intentionally supports
  tools only; roots, sampling, elicitation, resources, and prompts are refused.
  """

  alias Alto.External.JSONRPC

  @protocol_version "2025-11-25"
  @default_timeout 30_000

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
    GenServer.call(
      pid,
      {:list_tools, %{}, JSONRPC.deadline(timeout)},
      JSONRPC.call_timeout(timeout)
    )
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
      {:call_tool, %{"name" => name, "arguments" => arguments}, JSONRPC.deadline(timeout)},
      JSONRPC.call_timeout(timeout)
    )
  catch
    :exit, {:noproc, _} = reason -> {:error, {:mcp_client_unavailable, reason}}
    :exit, reason -> {:unknown, {:mcp_client_unavailable, reason}}
  end

  @doc "Stop a retained external server. Primarily useful for host shutdown and tests."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid, :normal)

  def initial_state(_opts), do: %{tools: nil}

  def initialize(state) do
    %{
      "protocolVersion" => Keyword.fetch!(state.opts, :protocol_version),
      "capabilities" => %{},
      "clientInfo" => %{"name" => "alto", "version" => "0.1.0"}
    }
  end

  def handle_call({:list_tools, _params, _timeout}, _from, %{phase: :ready, tools: tools} = state)
      when is_list(tools),
      do: {:reply, {:ok, tools}, state}

  def handle_call({kind, params, deadline}, from, %{phase: :ready} = state)
      when kind in [:list_tools, :call_tool] do
    method = if kind == :list_tools, do: "tools/list", else: "tools/call"

    JSONRPC.handle_request(
      state,
      method,
      params,
      from,
      deadline,
      if(kind == :call_tool, do: :unknown, else: :error)
    )
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, {:mcp_not_ready, state.phase}}, state}

  @options_schema [
    command: [type: :string, required: true],
    protocol_version: [type: :any, default: @protocol_version],
    request_timeout: [type: :pos_integer, default: @default_timeout],
    max_message_bytes: [type: :pos_integer, default: 2_000_000]
  ]

  defp normalize_options(opts), do: JSONRPC.normalize_options(opts, @options_schema)

  def initialized(result, state) do
    expected = Keyword.fetch!(state.opts, :protocol_version)

    if result["protocolVersion"] == expected do
      with :ok <- JSONRPC.notify(state, "notifications/initialized"), do: {:ok, state}
    else
      {:error, {:mcp_initialize_protocol_mismatch, expected, result["protocolVersion"]}}
    end
  end

  def result("tools/list", %{"tools" => tools}, state) when is_list(tools),
    do: {{:ok, tools}, %{state | tools: tools}}

  def result("tools/list", result, state), do: {{:error, {:invalid_mcp_tools, result}}, state}
  def result("tools/call", result, state), do: {normalize_tool_result(result), state}

  defp normalize_tool_result(%{"isError" => true} = result),
    do: {:error, {:mcp_tool_error, result}}

  defp normalize_tool_result(result), do: {:ok, result}

  def handle_message(%{"method" => _method, "id" => id}, state) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Alto MCP client supports tools only"}
    }

    _ = JSONRPC.send_payload(state, response)
    {:ok, state}
  end

  def handle_message(_notification, state), do: {:ok, state}

  def cancel_request(state, id, reason) do
    JSONRPC.notify(state, "notifications/cancelled", %{"requestId" => id, "reason" => reason})
  end
end
