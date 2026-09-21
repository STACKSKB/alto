defmodule Alto.Codex.AppServer.Client do
  @moduledoc """
  Supervised JSON-RPC client for the official Codex App Server.

  App Server owns ChatGPT OAuth tokens and refresh. Alto only receives account
  metadata, model catalogs, quota snapshots, and streamed agent events. One
  process is retained per command/configuration tuple so OAuth callbacks and
  loaded Codex threads survive individual turns.
  """

  use GenServer
  alias Alto.External.JSONRPC
  alias Alto.External.Process, as: ExternalProcess

  @default_timeout 30_000
  @default_turn_timeout 120_000
  @default_max_message_bytes 8_000_000
  @default_max_pending_requests 128
  @default_max_ready_waiters 128
  @default_max_subscribers 128

  @type options :: keyword()

  @doc "Start or reuse the configured App Server and complete its handshake."
  @spec ensure_started(options()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(opts \\ []) when is_list(opts) do
    with {:ok, opts} <- normalize_options(opts) do
      JSONRPC.ensure_started(__MODULE__, opts)
    end
  end

  @doc "Receive App Server notifications and server requests in the calling process."
  @spec subscribe(pid(), pid()) :: :ok | {:error, term()}
  def subscribe(client, subscriber \\ self()) when is_pid(subscriber) do
    GenServer.call(client, {:subscribe, subscriber})
  catch
    :exit, reason -> {:error, {:codex_app_server_unavailable, reason}}
  end

  @doc "Issue a supported App Server JSON-RPC request."
  @spec request(pid(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def request(client, method, params \\ %{}, timeout \\ @default_turn_timeout)
      when is_binary(method) and is_map(params) do
    GenServer.call(
      client,
      {:request, method, params, JSONRPC.deadline(timeout)},
      JSONRPC.call_timeout(timeout)
    )
  catch
    :exit, reason -> {:error, {:codex_app_server_unavailable, reason}}
  end

  @doc "Reply to a server-initiated request such as an approval prompt."
  @spec respond(pid(), String.t() | integer(), map()) :: :ok | {:error, term()}
  def respond(client, id, result) when (is_binary(id) or is_integer(id)) and is_map(result) do
    GenServer.call(client, {:respond, id, result})
  catch
    :exit, reason -> {:error, {:codex_app_server_unavailable, reason}}
  end

  @doc "Reject a server-initiated request that Alto cannot safely service."
  @spec reject(pid(), String.t() | integer(), integer(), String.t()) :: :ok | {:error, term()}
  def reject(client, id, code \\ -32601, message \\ "unsupported by Alto")
      when (is_binary(id) or is_integer(id)) and is_integer(code) and is_binary(message) do
    GenServer.call(client, {:reject, id, code, message})
  catch
    :exit, reason -> {:error, {:codex_app_server_unavailable, reason}}
  end

  def account(client), do: request(client, "account/read", %{"refreshToken" => false})

  def models(client),
    do: request(client, "model/list", %{"limit" => 100, "includeHidden" => false})

  def rate_limits(client), do: request(client, "account/rateLimits/read")

  def login_chatgpt(client) do
    request(client, "account/login/start", %{
      "type" => "chatgpt",
      "useHostedLoginSuccessPage" => true,
      "appBrand" => "chatgpt"
    })
  end

  def logout(client), do: request(client, "account/logout")
  def start_thread(client, params), do: request(client, "thread/start", params)
  def resume_thread(client, params), do: request(client, "thread/resume", params)

  def read_thread(client, thread_id),
    do: request(client, "thread/read", %{"threadId" => thread_id, "includeTurns" => true})

  def start_turn(client, params), do: request(client, "turn/start", params)

  def interrupt_turn(client, thread_id, turn_id),
    do: request(client, "turn/interrupt", %{"threadId" => thread_id, "turnId" => turn_id})

  @doc false
  def child_spec(opts) do
    JSONRPC.child_spec(__MODULE__, opts)
  end

  def start_link(opts), do: JSONRPC.start_link(__MODULE__, opts)

  @impl true
  def format_status(status), do: JSONRPC.format_status(status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, JSONRPC.state(opts, %{subscribers: %{}}), {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    params = %{
      "clientInfo" => %{"name" => "alto", "title" => "Alto", "version" => "0.1.0"},
      "capabilities" => %{"experimentalApi" => false}
    }

    case JSONRPC.open(
           state,
           &open_port/1,
           &send_request(&1, "initialize", params, :initialize, false)
         ) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:stop, reason, fail_all(state, reason)}
    end
  end

  @impl true
  def handle_call(:await_ready, from, state),
    do: JSONRPC.await_ready(state, from, :codex_app_server_ready_waiter_limit)

  def handle_call({:subscribe, subscriber}, _from, state) do
    if Map.has_key?(state.subscribers, subscriber) do
      {:reply, :ok, state}
    else
      if map_size(state.subscribers) >= Keyword.fetch!(state.opts, :max_subscribers) do
        {:reply,
         {:error,
          {:codex_app_server_subscriber_limit, Keyword.fetch!(state.opts, :max_subscribers)}},
         state}
      else
        monitor = Process.monitor(subscriber)
        {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, subscriber, monitor)}}
      end
    end
  end

  def handle_call({:request, method, params, deadline}, from, %{phase: :ready} = state) do
    case send_request(
           state,
           method,
           params,
           {:request, from, method},
           true,
           JSONRPC.remaining(deadline)
         ) do
      {:ok, state} ->
        {:noreply, state}

      {:error, :request_expired} ->
        {:reply, {:error, :request_expired}, state}

      {:error, {:codex_app_server_pending_request_limit, _} = reason} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:stop, reason, {:error, reason}, fail_all(state, reason)}
    end
  end

  def handle_call({:respond, id, result}, _from, %{phase: :ready} = state) do
    {:reply, send_payload(state, %{"jsonrpc" => "2.0", "id" => id, "result" => result}), state}
  end

  def handle_call({:reject, id, code, message}, _from, %{phase: :ready} = state) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }

    {:reply, send_payload(state, payload), state}
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, {:codex_app_server_not_ready, state.phase}}, state}

  @impl true
  def handle_info({port, {:data, data}}, %{process: %{port: port}} = state) do
    case JSONRPC.ingest(state, data, :codex_app_server_message_limit, &consume_lines/1) do
      {:ok, next} -> {:noreply, next}
      {:error, reason, next} -> {:stop, reason, fail_all(next, reason)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{process: %{port: port}} = state) do
    reason = {:codex_app_server_exit, status}
    {:stop, reason, fail_all(state, reason)}
  end

  def handle_info({:EXIT, port, reason}, %{process: %{port: port}} = state) do
    failure = {:codex_app_server_exit, reason}
    {:stop, failure, fail_all(state, failure)}
  end

  def handle_info(:initialize_timeout, %{phase: :starting} = state) do
    reason = {:codex_app_server_startup_timeout, Keyword.fetch!(state.opts, :startup_timeout)}
    {:stop, reason, fail_all(state, reason)}
  end

  def handle_info(:initialize_timeout, state), do: {:noreply, state}

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{reply: reply, timer: timer, owner: owner, monitor: monitor}, pending} ->
        JSONRPC.cancel_timer(timer)
        cancel_request(state, id)
        JSONRPC.demonitor(owner, monitor)
        reply_error(reply, {:codex_app_server_request_timeout, id})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    state = JSONRPC.drop_owner(state, monitor, owner, &cancel_request(state, &1))
    subscribers = Map.reject(state.subscribers, fn {_pid, ref} -> ref == monitor end)
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: JSONRPC.close(state)

  @options_schema [
    command: [type: :string, default: "codex"],
    args: [type: {:list, :string}, default: ["app-server", "--stdio"]],
    cwd: [type: :string],
    env: [type: {:map, :any, :any}, default: %{}],
    instance: [type: :any, default: :shared],
    startup_timeout: [type: :pos_integer, default: @default_timeout],
    request_timeout: [type: :pos_integer, default: @default_turn_timeout],
    max_message_bytes: [type: :pos_integer, default: @default_max_message_bytes],
    max_pending_requests: [type: :pos_integer, default: @default_max_pending_requests],
    max_ready_waiters: [type: :pos_integer, default: @default_max_ready_waiters],
    max_subscribers: [type: :pos_integer, default: @default_max_subscribers]
  ]

  defp normalize_options(opts), do: JSONRPC.normalize_options(opts, @options_schema)

  defp open_port(opts) do
    command = Keyword.fetch!(opts, :command)

    case ExternalProcess.open(command, Keyword.fetch!(opts, :args),
           cwd: Keyword.fetch!(opts, :cwd),
           env: Keyword.fetch!(opts, :env),
           startup_timeout: Keyword.fetch!(opts, :startup_timeout)
         ) do
      {:ok, _process} = ok -> ok
      {:error, reason} -> {:error, {:codex_app_server_port_open_failed, reason}}
    end
  rescue
    error in ArgumentError ->
      {:error, {:codex_app_server_port_open_failed, Exception.message(error)}}
  end

  defp send_request(state, method, params, reply, monitor_owner, timeout \\ nil) do
    owner = if monitor_owner, do: elem(elem(reply, 1), 0), else: nil

    JSONRPC.request(
      state,
      method,
      params,
      reply,
      owner,
      timeout,
      :codex_app_server_pending_request_limit
    )
  end

  defp send_notification(state, method, params \\ %{}) do
    send_payload(state, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp send_payload(state, payload),
    do: JSONRPC.send(state.process.port, payload, Keyword.fetch!(state.opts, :max_message_bytes))

  defp consume_lines(state), do: JSONRPC.consume_lines(state, &handle_line/2)

  defp handle_line("", state), do: {:ok, state}

  defp handle_line(line, state) do
    case JSON.decode(line) do
      {:ok, message} when is_map(message) ->
        handle_message(message, state)

      {:ok, _other} ->
        {:error, :codex_app_server_message_not_object, state}

      {:error, error} ->
        {:error, {:codex_app_server_invalid_json, Exception.message(error)}, state}
    end
  end

  # Server requests carry both method and id. They must be handled before
  # looking up pending response ids, otherwise a request can steal a reply.
  defp handle_message(%{"method" => method, "id" => id} = message, state)
       when is_binary(method) do
    broadcast(state, {:codex_request, self(), id, method, message["params"] || %{}})
    {:ok, state}
  end

  defp handle_message(%{"id" => id} = message, state),
    do: JSONRPC.settle(state, id, message, &settle_response/3)

  defp handle_message(%{"method" => method} = notification, state) do
    broadcast(
      state,
      {:codex_notification, self(), method, Map.get(notification, "params", %{})}
    )

    {:ok, state}
  end

  defp handle_message(_message, state), do: {:ok, state}

  defp settle_response(:initialize, %{"result" => result}, state) when is_map(result) do
    case send_notification(state, "initialized") do
      :ok ->
        {:ok, JSONRPC.ready(state)}

      {:error, reason} ->
        {:error, reason, JSONRPC.fail_waiters(state, reason)}
    end
  end

  defp settle_response(:initialize, %{"result" => result}, state) do
    reason = {:invalid_codex_app_server_initialize_result, result}
    {:error, {:codex_app_server_initialize_failed, reason}, JSONRPC.fail_waiters(state, reason)}
  end

  defp settle_response(:initialize, message, state) do
    reason = response_error(message)
    {:error, {:codex_app_server_initialize_failed, reason}, JSONRPC.fail_waiters(state, reason)}
  end

  defp settle_response({:request, from, _method}, %{"result" => result}, state) do
    GenServer.reply(from, {:ok, result})
    {:ok, state}
  end

  defp settle_response({:request, from, method}, message, state) do
    GenServer.reply(from, {:error, {:codex_app_server_error, method, response_error(message)}})
    {:ok, state}
  end

  defp response_error(%{"error" => error}), do: error
  defp response_error(message), do: {:invalid_codex_app_server_response, message}

  defp broadcast(state, message),
    do: Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, message) end)

  defp cancel_request(state, id) do
    _ =
      send_payload(state, %{
        "jsonrpc" => "2.0",
        "method" => "$/cancelRequest",
        "params" => %{"id" => id}
      })

    :ok
  end

  defp fail_all(state, reason), do: JSONRPC.fail_all(state, reason, &reply_error/2)

  defp reply_error(:initialize, _reason), do: :ok
  defp reply_error({:request, from, _method}, reason), do: GenServer.reply(from, {:error, reason})
end
