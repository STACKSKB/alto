defmodule Alto.Listeners.Webhook do
  @moduledoc """
  Verified, bounded HTTP ingress for external webhooks.

  `alto.exs` chooses whether an accepted delivery starts a shallow Alto run or
  is handed to a configured durable inbox. Bandit and Plug own HTTP parsing and
  connection lifecycle; Alto owns verification, delivery identity, admission,
  and run dispatch.
  """

  use GenServer

  alias Alto.FrontEnd.Registry

  @default_max_body_bytes 262_144
  @default_max_delivery_ids 10_000
  @max_delivery_id_bytes 200
  @recv_timeout 5_000
  @request_errors %{
    too_large: {413, "payload too large"},
    bad_length: {400, "bad content length"},
    bad_signature: {401, "signature verification failed"},
    missing_signature: {401, "signature verification failed"},
    duplicate_signature: {401, "signature verification failed"},
    signature_too_large: {401, "signature verification failed"},
    invalid_verify: {401, "signature verification failed"},
    missing_delivery_id: {400, "missing delivery id"},
    delivery_id_too_large: {400, "delivery id too large"},
    duplicate_delivery_id: {400, "duplicate delivery id"},
    invalid_identity: {400, "invalid delivery id"},
    invalid_delivery_id: {400, "invalid delivery id"}
  }
  @admission_errors %{
    duplicate: {200, "duplicate"},
    key_claimed: {200, "duplicate"},
    payload_too_large: {413, "payload too large"},
    invalid_key: {400, "delivery id too large"},
    queue_full: {503, "inbox full"},
    full: {503, "inbox full"}
  }

  defmodule Endpoint do
    @moduledoc false
    @enforce_keys [:path, :verify, :identity, :on_event]
    defstruct [
      :path,
      :verify,
      :identity,
      :on_event,
      source: nil,
      max_body_bytes: 262_144,
      delivery_ids: []
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The port the listener actually bound (useful with an ephemeral port)."
  @spec bound_port(GenServer.server()) :: :inet.port_number()
  def bound_port(server \\ __MODULE__), do: GenServer.call(server, :bound_port)

  @impl true
  def init(opts) do
    registry = Keyword.fetch!(opts, :registry)
    port = Keyword.get(opts, :port, 0)

    with {:ok, endpoints} <- build_endpoints(Keyword.fetch!(opts, :endpoints)),
         {:ok, bandit} <-
           Bandit.start_link(
             plug:
               {__MODULE__.Router, registry: registry, listener: self(), endpoints: endpoints},
             ip: {127, 0, 0, 1},
             port: port,
             startup_log: false,
             http_options: [log_protocol_errors: false, log_client_closures: false]
           ),
         {:ok, {_address, actual_port}} <- ThousandIsland.listener_info(bandit) do
      {:ok, %{bandit: bandit, port: actual_port, endpoints: endpoints}}
    else
      {:error, reason} -> {:stop, {:webhook_listener_failed, reason}}
      :error -> {:stop, {:webhook_listener_failed, :listener_info_unavailable}}
    end
  end

  @impl true
  def handle_call(:bound_port, _from, state), do: {:reply, state.port, state}

  def handle_call({:claim_delivery, path, delivery_id}, _from, state) do
    endpoint = Map.fetch!(state.endpoints, path)

    if delivery_id in endpoint.delivery_ids do
      {:reply, :duplicate, state}
    else
      endpoint = %{
        endpoint
        | delivery_ids:
            Enum.take([delivery_id | endpoint.delivery_ids], @default_max_delivery_ids)
      }

      {:reply, :new, put_in(state.endpoints[path], endpoint)}
    end
  end

  def handle_call({:release_delivery, path, delivery_id}, _from, state) do
    endpoint = Map.fetch!(state.endpoints, path)
    endpoint = %{endpoint | delivery_ids: List.delete(endpoint.delivery_ids, delivery_id)}
    {:reply, :ok, put_in(state.endpoints[path], endpoint)}
  end

  @impl true
  def terminate(_reason, %{bandit: bandit}) do
    if Process.alive?(bandit), do: Supervisor.stop(bandit)
    :ok
  end

  @doc false
  def handle_http(conn, opts) do
    endpoints = Keyword.fetch!(opts, :endpoints)

    case route(endpoints, conn.method, conn.request_path) do
      {:ok, endpoint} -> serve_endpoint(conn, endpoint, opts)
      {:error, :method} -> respond(conn, 405, "method not allowed")
      {:error, :not_found} -> respond(conn, 404, "not found")
    end
  end

  defp serve_endpoint(conn, %Endpoint{} = endpoint, opts) do
    with {:ok, body, conn} <- read_body(conn, endpoint.max_body_bytes),
         :ok <- verify(endpoint, conn, body),
         {:ok, delivery_id} <- identity(endpoint, conn) do
      dispatch(conn, endpoint, delivery_id, body, opts)
    else
      {:error, reason, conn} -> request_error(conn, reason)
      {:error, reason} -> request_error(conn, reason)
    end
  end

  defp request_error(conn, reason) do
    {status, body} = Map.get(@request_errors, reason, {500, "webhook validation failed"})
    respond(conn, status, body)
  end

  defp dispatch(
         conn,
         %Endpoint{on_event: {:start_run, config}} = endpoint,
         delivery_id,
         body,
         opts
       ) do
    listener = Keyword.fetch!(opts, :listener)
    registry = Keyword.fetch!(opts, :registry)

    case GenServer.call(listener, {:claim_delivery, endpoint.path, delivery_id}) do
      :duplicate ->
        respond(conn, 200, "duplicate")

      :new ->
        case Registry.start_run(registry, config, body) do
          {:ok, _run_id} ->
            respond(conn, 200, "accepted")

          {:error, reason} ->
            GenServer.call(listener, {:release_delivery, endpoint.path, delivery_id})
            log_rejected(endpoint, "run failed to start: #{inspect(reason)}")
            respond(conn, 500, "run failed to start")
        end
    end
  end

  defp dispatch(
         conn,
         %Endpoint{on_event: {:enqueue, {backend, backend_opts}}} = endpoint,
         delivery_id,
         body,
         _opts
       ) do
    key = endpoint.source <> ":" <> delivery_id
    payload = %{"delivery_id" => delivery_id, "body" => body}

    case Alto.Inbox.admit(backend, key, payload, backend_opts) do
      {:ok, _record} -> respond(conn, 200, "accepted")
      {:error, reason} -> enqueue_error(conn, endpoint, reason)
    end
  end

  defp enqueue_error(conn, endpoint, reason) do
    kind =
      case reason do
        {name, _} when name in [:key_claimed, :payload_too_large, :invalid_key] -> name
        other -> other
      end

    case Map.fetch(@admission_errors, kind) do
      {:ok, {status, body}} ->
        respond(conn, status, body)

      :error ->
        log_rejected(endpoint, "enqueue failed: #{inspect(reason)}")
        respond(conn, 500, "enqueue failed")
    end
  end

  defp read_body(conn, max) do
    case Plug.Conn.get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value, 10) do
          {length, ""} when length >= 0 and length <= max -> read_body_chunks(conn, max)
          {length, ""} when length > max -> {:error, :too_large, conn}
          _other -> {:error, :bad_length, conn}
        end

      [] ->
        read_body_chunks(conn, max)

      _other ->
        {:error, :bad_length, conn}
    end
  end

  defp read_body_chunks(conn, max),
    do: read_body_chunks(conn, max, [], 0, System.monotonic_time(:millisecond) + @recv_timeout)

  defp read_body_chunks(conn, max, chunks, total, deadline) do
    case Plug.Conn.read_body(conn,
           length: max - total + 1,
           read_length: min(max - total + 1, 64_000),
           read_timeout: max(deadline - System.monotonic_time(:millisecond), 1)
         ) do
      {status, body, conn} when status in [:ok, :more] ->
        total = total + byte_size(body)

        cond do
          total > max -> {:error, :too_large, conn}
          status == :ok -> {:ok, IO.iodata_to_binary([chunks, body]), conn}
          System.monotonic_time(:millisecond) >= deadline -> {:error, :bad_length, conn}
          true -> read_body_chunks(conn, max, [chunks, body], total, deadline)
        end

      {:error, _reason} ->
        {:error, :bad_length, conn}
    end
  end

  defp verify(%Endpoint{verify: verifier}, conn, body) do
    normalize_verifier_result(invoke_callback(verifier, :verify, [body, conn.req_headers]))
  end

  defp identity(%Endpoint{identity: extractor}, conn),
    do: normalize_identity_result(invoke_callback(extractor, :extract, [conn.req_headers]))

  defp invoke_callback({module, opts}, callback, args) when is_atom(module),
    do: apply(module, callback, args ++ [opts])

  defp invoke_callback({fun, opts}, _callback, args), do: apply(fun, args ++ [opts])

  defp normalize_verifier_result(:ok), do: :ok
  defp normalize_verifier_result({:error, reason}), do: {:error, reason}
  defp normalize_verifier_result(_other), do: {:error, :invalid_verify}

  defp normalize_identity_result({:ok, id})
       when is_binary(id) and id != "" and byte_size(id) <= @max_delivery_id_bytes,
       do: {:ok, id}

  defp normalize_identity_result({:error, reason}), do: {:error, reason}
  defp normalize_identity_result(_other), do: {:error, :invalid_identity}

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain", "utf-8")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
    |> Plug.Conn.send_resp(status, body)
  end

  defp route(endpoints, "POST", path) do
    case Map.fetch(endpoints, path) do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> {:error, :not_found}
    end
  end

  defp route(endpoints, _method, path) do
    if Map.has_key?(endpoints, path), do: {:error, :method}, else: {:error, :not_found}
  end

  defp build_endpoints(specs) when is_list(specs) and specs != [] do
    with {:ok, endpoints} <- Alto.Result.traverse(specs, &build_endpoint/1) do
      case endpoints |> Enum.map(& &1.path) |> duplicate_value() do
        nil -> {:ok, Map.new(endpoints, &{&1.path, &1})}
        path -> {:error, {:duplicate_endpoint_path, path}}
      end
    end
  end

  defp build_endpoints(_specs), do: {:error, :invalid_endpoints}

  defp build_endpoint(spec) when is_map(spec) do
    with {:ok, path} <- endpoint_path(spec),
         {:ok, verify} <- endpoint_verify(Map.get(spec, :verify)),
         {:ok, identity} <- endpoint_identity(Map.get(spec, :identity)),
         {:ok, on_event} <- endpoint_on_event(Map.get(spec, :on_event)),
         {:ok, max_body_bytes} <-
           max_body_bytes(Map.get(spec, :max_body_bytes, @default_max_body_bytes)),
         {:ok, source} <- endpoint_source(Map.get(spec, :source, path)) do
      {:ok,
       %Endpoint{
         path: path,
         verify: verify,
         identity: identity,
         on_event: on_event,
         source: source,
         max_body_bytes: max_body_bytes
       }}
    end
  end

  defp build_endpoint(_spec), do: {:error, :invalid_endpoints}

  defp endpoint_path(%{path: path}) when is_binary(path) and byte_size(path) > 1 do
    if String.starts_with?(path, "/") and not String.contains?(path, [<<0>>, "\n", "\r"]),
      do: {:ok, path},
      else: {:error, {:invalid_path, path}}
  end

  defp endpoint_path(_spec), do: {:error, :invalid_path}

  defp endpoint_verify(value), do: endpoint_callback(value, :verify, 3, :invalid_verify)
  defp endpoint_identity(value), do: endpoint_callback(value, :extract, 2, :invalid_identity)

  defp endpoint_callback({module, opts} = value, callback, arity, error)
       when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, callback, arity),
      do: {:ok, value},
      else: {:error, error}
  end

  defp endpoint_callback({fun, opts} = value, _callback, arity, _error)
       when is_function(fun, arity) and is_list(opts),
       do: {:ok, value}

  defp endpoint_callback(_value, _callback, _arity, error), do: {:error, error}

  defp endpoint_source(source)
       when is_binary(source) and source != "" and byte_size(source) <= 256,
       do:
         if(String.contains?(source, [<<0>>, "\n", "\r"]),
           do: {:error, {:invalid_source, source}},
           else: {:ok, source}
         )

  defp endpoint_source(_source), do: {:error, :invalid_source}

  defp duplicate_value(values) do
    values
    |> Enum.frequencies()
    |> Enum.find_value(fn {value, count} -> if count > 1, do: value end)
  end

  defp endpoint_on_event({:start_run, config}) when is_binary(config) and config != "",
    do: {:ok, {:start_run, config}}

  defp endpoint_on_event({:enqueue, {backend, opts}})
       when is_atom(backend) and is_list(opts) do
    case Alto.Inbox.validate_backend(backend, opts) do
      :ok -> {:ok, {:enqueue, {backend, opts}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp endpoint_on_event(_other), do: {:error, :invalid_on_event}

  defp max_body_bytes(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp max_body_bytes(_value), do: {:error, :invalid_max_body_bytes}

  defp log_rejected(%Endpoint{path: path}, detail) do
    IO.puts(:stderr, "alto webhook: #{path} rejected — #{detail}")
  end

  defmodule Router do
    @moduledoc false
    def init(opts), do: opts
    def call(conn, opts), do: Alto.Listeners.Webhook.handle_http(conn, opts)
  end
end
