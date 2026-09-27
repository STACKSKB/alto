defmodule Alto.Codex.AppServer.Client do
  @moduledoc """
  Supervised JSON-RPC client for the official Codex App Server.

  App Server owns ChatGPT OAuth tokens and refresh. Alto only receives account
  metadata, model catalogs, quota snapshots, and streamed agent events. One
  process is retained per command/configuration tuple so OAuth callbacks and
  loaded Codex threads survive individual turns.
  """

  alias Alto.External.JSONRPC

  @default_turn_timeout 120_000

  @options_schema [
    command: [type: :string, default: "codex"],
    args: [type: {:list, :string}, default: ["app-server", "--stdio"]],
    experimental_api: [type: :boolean, default: false],
    instance: [type: :any, default: :shared],
    owner: [type: :pid],
    request_timeout: [type: :pos_integer, default: @default_turn_timeout],
    max_message_bytes: [type: :pos_integer, default: 8_000_000],
    max_subscribers: [type: :pos_integer, default: 128]
  ]

  @type options :: keyword()

  @doc "Start or reuse the configured App Server and complete its handshake."
  @spec ensure_started(options()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(opts \\ []) when is_list(opts) do
    JSONRPC.ensure_started(__MODULE__, opts, @options_schema)
  end

  @doc "Receive App Server notifications and server requests in the calling process."
  @spec subscribe(pid(), pid()) :: :ok | {:error, term()}
  def subscribe(client, subscriber \\ self()) when is_pid(subscriber) do
    JSONRPC.call(client, {:subscribe, subscriber})
  end

  @doc "Issue a supported App Server JSON-RPC request."
  @spec request(pid(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def request(client, method, params \\ %{}, timeout \\ @default_turn_timeout)
      when is_binary(method) and is_map(params) do
    JSONRPC.call(
      client,
      {:request, method, params, JSONRPC.deadline(timeout)},
      JSONRPC.call_timeout(timeout)
    )
  end

  @doc "Reply to a server-initiated request such as an approval prompt."
  @spec respond(pid(), String.t() | integer(), map()) :: :ok | {:error, term()}
  def respond(client, id, result) when (is_binary(id) or is_integer(id)) and is_map(result) do
    JSONRPC.call(client, {:respond, id, result})
  end

  @doc "Reject a server-initiated request that Alto cannot safely service."
  @spec reject(pid(), String.t() | integer(), integer(), String.t()) :: :ok | {:error, term()}
  def reject(client, id, code \\ -32601, message \\ "unsupported by Alto")
      when (is_binary(id) or is_integer(id)) and is_integer(code) and is_binary(message) do
    JSONRPC.call(client, {:reject, id, code, message})
  end

  def account(client), do: request(client, "account/read", %{"refreshToken" => false})

  def models(client, cursor \\ nil),
    do:
      request(client, "model/list", %{
        "limit" => 100,
        "includeHidden" => false,
        "cursor" => cursor
      })

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

  def initial_state(_opts), do: %{subscribers: %{}}

  def initialize(state) do
    %{
      "clientInfo" => %{"name" => "alto", "title" => "Alto", "version" => "0.1.0"},
      "capabilities" => %{"experimentalApi" => Keyword.get(state.opts, :experimental_api, false)}
    }
  end

  def handle_call({:subscribe, subscriber}, _from, state) do
    limit = Keyword.fetch!(state.opts, :max_subscribers)

    if not Map.has_key?(state.subscribers, subscriber) and map_size(state.subscribers) >= limit do
      {:reply, {:error, {:codex_app_server_subscriber_limit, limit}}, state}
    else
      subscribers =
        Map.put_new_lazy(state.subscribers, subscriber, fn -> Process.monitor(subscriber) end)

      {:reply, :ok, %{state | subscribers: subscribers}}
    end
  end

  def handle_call({:request, method, params, deadline}, from, %{phase: :ready} = state) do
    JSONRPC.handle_request(state, method, params, from, deadline)
  end

  def handle_call({:respond, id, result}, _from, %{phase: :ready} = state) do
    {:reply, JSONRPC.send_payload(state, %{"jsonrpc" => "2.0", "id" => id, "result" => result}),
     state}
  end

  def handle_call({:reject, id, code, message}, _from, %{phase: :ready} = state) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }

    {:reply, JSONRPC.send_payload(state, payload), state}
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, {:codex_app_server_not_ready, state.phase}}, state}

  def owner_down(state, monitor),
    do: %{
      state
      | subscribers: Map.reject(state.subscribers, fn {_pid, ref} -> ref == monitor end)
    }

  # Server requests carry both method and id. They must be handled before
  # looking up pending response ids, otherwise a request can steal a reply.
  def handle_message(%{"method" => method, "id" => id} = message, state)
      when is_binary(method) do
    broadcast(state, {:codex_request, self(), id, method, message["params"] || %{}})
    {:ok, state}
  end

  def handle_message(%{"method" => method} = notification, state) do
    broadcast(
      state,
      {:codex_notification, self(), method, Map.get(notification, "params", %{})}
    )

    {:ok, state}
  end

  def handle_message(_message, state), do: {:ok, state}

  def initialized(_result, state) do
    with :ok <- JSONRPC.notify(state, "initialized"), do: {:ok, state}
  end

  def result(_method, result, state), do: {{:ok, result}, state}

  defp broadcast(state, message),
    do: Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, message) end)

  def cancel_request(state, id, _reason) do
    JSONRPC.notify(state, "$/cancelRequest", %{"id" => id})
  end
end
