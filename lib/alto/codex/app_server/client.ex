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
      key = client_key(opts)
      name = {:via, Registry, {Alto.External.Registry, key}}
      child = {__MODULE__, Keyword.put(opts, :name, name)}

      case DynamicSupervisor.start_child(Alto.External.Supervisor, child) do
        {:ok, pid} ->
          await_ready(pid, Keyword.fetch!(opts, :startup_timeout))

        {:error, {:already_started, pid}} ->
          await_ready(pid, Keyword.fetch!(opts, :startup_timeout))

        {:error, reason} ->
          {:error, {:codex_app_server_start_failed, reason}}
      end
    end
  catch
    :exit, reason -> {:error, {:codex_app_server_supervisor_unavailable, reason}}
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
      call_timeout(timeout)
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
    %{
      id: {__MODULE__, Keyword.get(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

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
      subscribers: %{},
      initialize_timer: nil
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    case open_port(state.opts) do
      {:ok, process} ->
        params = %{
          "clientInfo" => %{"name" => "alto", "title" => "Alto", "version" => "0.1.0"},
          "capabilities" => %{"experimentalApi" => false}
        }

        state = %{state | process: process, port: ExternalProcess.port(process)}

        case send_request(state, "initialize", params, :initialize, false) do
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
        {:stop, reason, fail_all(state, reason)}
    end
  end

  @impl true
  def handle_call(:await_ready, _from, %{phase: :ready} = state),
    do: {:reply, {:ok, self()}, state}

  def handle_call(:await_ready, _from, %{phase: {:failed, reason}} = state),
    do: {:reply, {:error, reason}, state}

  def handle_call(:await_ready, from, state),
    do: add_ready_waiter(from, state)

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
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data

    if byte_size(buffer) > Keyword.fetch!(state.opts, :max_message_bytes) do
      reason = {:codex_app_server_message_limit, Keyword.fetch!(state.opts, :max_message_bytes)}
      {:stop, reason, fail_all(state, reason)}
    else
      case consume_lines(%{state | buffer: buffer}) do
        {:ok, next} -> {:noreply, next}
        {:error, reason, next} -> {:stop, reason, fail_all(next, reason)}
      end
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = {:codex_app_server_exit, status}
    {:stop, reason, fail_all(state, reason)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
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
        cancel_timer(timer)
        cancel_request(state, id)
        demonitor(owner, monitor)
        reply_error(reply, {:codex_app_server_request_timeout, id})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case Enum.find(state.pending, fn {_id, entry} ->
           entry.monitor == monitor and entry.owner == owner
         end) do
      {id, %{timer: timer}} ->
        cancel_request(state, id)
        cancel_timer(timer)
        {:noreply, %{state | pending: Map.delete(state.pending, id)}}

      nil ->
        ready_waiters = Enum.reject(state.ready_waiters, fn {_from, ref} -> ref == monitor end)

        subscribers =
          case Enum.find(state.subscribers, fn {_pid, ref} -> ref == monitor end) do
            {subscriber, ^monitor} -> Map.delete(state.subscribers, subscriber)
            nil -> state.subscribers
          end

        {:noreply, %{state | ready_waiters: ready_waiters, subscribers: subscribers}}
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

  defp normalize_options(opts) do
    defaults = [
      command: "codex",
      args: ["app-server", "--stdio"],
      cwd: File.cwd!(),
      env: %{},
      instance: :shared,
      startup_timeout: @default_timeout,
      request_timeout: @default_turn_timeout,
      max_message_bytes: @default_max_message_bytes,
      max_pending_requests: @default_max_pending_requests,
      max_ready_waiters: @default_max_ready_waiters,
      max_subscribers: @default_max_subscribers
    ]

    with {:ok, opts} <- Keyword.validate(opts, defaults),
         command when is_binary(command) and command != "" <- Keyword.fetch!(opts, :command),
         executable when is_binary(executable) <- resolve_executable(command),
         args when is_list(args) <- Keyword.fetch!(opts, :args),
         true <- Enum.all?(args, &is_binary/1),
         cwd when is_binary(cwd) <- Keyword.fetch!(opts, :cwd),
         true <- File.dir?(cwd),
         env when is_map(env) <- Keyword.fetch!(opts, :env),
         :ok <- positive_options(opts) do
      {:ok, Keyword.put(opts, :command, executable)}
    else
      {:error, reason} -> {:error, {:invalid_codex_app_server_options, reason}}
      nil -> {:error, {:codex_executable_not_found, Keyword.get(opts, :command)}}
      _other -> {:error, {:invalid_codex_app_server_options, opts}}
    end
  end

  defp resolve_executable(command),
    do: System.find_executable(command) || if(File.regular?(command), do: Path.expand(command))

  defp positive_options(opts) do
    keys = [
      :startup_timeout,
      :request_timeout,
      :max_message_bytes,
      :max_pending_requests,
      :max_ready_waiters,
      :max_subscribers
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
        :instance,
        :startup_timeout,
        :request_timeout,
        :max_message_bytes,
        :max_pending_requests,
        :max_ready_waiters,
        :max_subscribers
      ])

    "codex-app-server:" <>
      Base.url_encode64(:crypto.hash(:sha256, :erlang.term_to_binary(identity)), padding: false)
  end

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

  defp send_request(state, method, params, reply, monitor_owner, timeout \\ nil)
  defp send_request(_state, _method, _params, _reply, _monitor, 0), do: {:error, :request_expired}

  defp send_request(state, method, params, reply, monitor_owner, timeout) do
    limit = Keyword.fetch!(state.opts, :max_pending_requests)

    if map_size(state.pending) >= limit do
      {:error, {:codex_app_server_pending_request_limit, limit}}
    else
      id = state.next_id
      payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

      case send_payload(state, payload) do
        :ok ->
          timer = start_timer(id, timeout || Keyword.fetch!(state.opts, :request_timeout))

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

  defp send_notification(state, method, params \\ %{}) do
    send_payload(state, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp send_payload(state, payload),
    do: JSONRPC.send(state.port, payload, Keyword.fetch!(state.opts, :max_message_bytes))

  defp consume_lines(state) do
    case :binary.split(state.buffer, "\n") do
      [rest] ->
        {:ok, %{state | buffer: rest}}

      [line, rest] ->
        with {:ok, next} <- handle_line(String.trim_trailing(line, "\r"), %{state | buffer: rest}) do
          consume_lines(next)
        end
    end
  end

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

  defp handle_message(%{"id" => id} = message, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:ok, state}

      {%{reply: reply, timer: timer, owner: owner, monitor: monitor}, pending} ->
        Process.cancel_timer(timer)
        demonitor(owner, monitor)
        settle_response(reply, message, %{state | pending: pending})
    end
  end

  defp handle_message(%{"method" => method} = notification, state) do
    broadcast(
      state,
      {:codex_notification, self(), method, Map.get(notification, "params", %{})}
    )

    {:ok, state}
  end

  defp handle_message(_message, state), do: {:ok, state}

  defp settle_response(:initialize, %{"result" => result}, state) when is_map(result) do
    if state.initialize_timer, do: cancel_timer(state.initialize_timer)

    case send_notification(state, "initialized") do
      :ok ->
        Enum.each(state.ready_waiters, fn {from, monitor} ->
          demonitor(elem(from, 0), monitor)
          GenServer.reply(from, {:ok, self()})
        end)

        {:ok, %{state | phase: :ready, ready_waiters: [], initialize_timer: nil}}

      {:error, reason} ->
        {:error, reason, fail_waiters(state, reason)}
    end
  end

  defp settle_response(:initialize, %{"result" => result}, state) do
    reason = {:invalid_codex_app_server_initialize_result, result}
    {:error, {:codex_app_server_initialize_failed, reason}, fail_waiters(state, reason)}
  end

  defp settle_response(:initialize, message, state) do
    reason = response_error(message)
    {:error, {:codex_app_server_initialize_failed, reason}, fail_waiters(state, reason)}
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

  defp add_ready_waiter(from, state) do
    limit = Keyword.fetch!(state.opts, :max_ready_waiters)

    if length(state.ready_waiters) >= limit do
      {:reply, {:error, {:codex_app_server_ready_waiter_limit, limit}}, state}
    else
      owner = elem(from, 0)
      monitor = Process.monitor(owner)
      {:noreply, %{state | ready_waiters: [{from, monitor} | state.ready_waiters]}}
    end
  end

  defp owner_monitor(_reply, false), do: {nil, nil}

  defp owner_monitor({_kind, from, _method}, true),
    do: {elem(from, 0), Process.monitor(elem(from, 0))}

  defp demonitor(nil, _monitor), do: :ok

  defp demonitor(_owner, monitor) when is_reference(monitor),
    do: Process.demonitor(monitor, [:flush])

  defp start_timer(_id, :infinity), do: nil
  defp start_timer(id, timeout), do: Process.send_after(self(), {:request_timeout, id}, timeout)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp cancel_request(state, id) do
    _ =
      send_payload(state, %{
        "jsonrpc" => "2.0",
        "method" => "$/cancelRequest",
        "params" => %{"id" => id}
      })

    :ok
  end

  defp await_ready(pid, timeout) do
    GenServer.call(pid, :await_ready, call_timeout(timeout))
  catch
    :exit, reason -> {:error, {:codex_app_server_startup_failed, reason}}
  end

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
    |> then(fn next ->
      Enum.each(next.pending, fn {_id,
                                  %{reply: reply, timer: timer, owner: owner, monitor: monitor}} ->
        cancel_timer(timer)
        demonitor(owner, monitor)
        reply_error(reply, reason)
      end)

      %{next | pending: %{}}
    end)
  end

  defp reply_error(:initialize, _reason), do: :ok
  defp reply_error({:request, from, _method}, reason), do: GenServer.reply(from, {:error, reason})

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout + 100
  defp call_timeout(_timeout), do: @default_turn_timeout
end
