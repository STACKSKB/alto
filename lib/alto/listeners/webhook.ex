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
    index = Enum.find_index(state.endpoints, &(&1.path == path))
    endpoint = Enum.fetch!(state.endpoints, index)

    if delivery_id in endpoint.delivery_ids do
      {:reply, :duplicate, state}
    else
      endpoint = %{
        endpoint
        | delivery_ids:
            Enum.take([delivery_id | endpoint.delivery_ids], @default_max_delivery_ids)
      }

      {:reply, :new, %{state | endpoints: List.replace_at(state.endpoints, index, endpoint)}}
    end
  end

  def handle_call({:release_delivery, path, delivery_id}, _from, state) do
    index = Enum.find_index(state.endpoints, &(&1.path == path))
    endpoint = Enum.fetch!(state.endpoints, index)
    endpoint = %{endpoint | delivery_ids: List.delete(endpoint.delivery_ids, delivery_id)}
    {:reply, :ok, %{state | endpoints: List.replace_at(state.endpoints, index, endpoint)}}
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
      {:error, :too_large, conn} ->
        respond(conn, 413, "payload too large")

      {:error, :bad_length, conn} ->
        respond(conn, 400, "bad content length")

      {:error, reason}
      when reason in [
             :bad_signature,
             :missing_signature,
             :duplicate_signature,
             :signature_too_large,
             :invalid_verify
           ] ->
        respond(conn, 401, "signature verification failed")

      {:error, :missing_delivery_id} ->
        respond(conn, 400, "missing delivery id")

      {:error, :delivery_id_too_large} ->
        respond(conn, 400, "delivery id too large")

      {:error, :duplicate_delivery_id} ->
        respond(conn, 400, "duplicate delivery id")

      {:error, :invalid_identity} ->
        respond(conn, 400, "invalid delivery id")

      {:error, :invalid_delivery_id} ->
        respond(conn, 400, "invalid delivery id")
    end
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

    result = Alto.Inbox.admit(backend, key, payload, backend_opts)

    case result do
      {:ok, _record} ->
        respond(conn, 200, "accepted")

      {:error, :duplicate} ->
        respond(conn, 200, "duplicate")

      {:error, {:key_claimed, _key}} ->
        respond(conn, 200, "duplicate")

      {:error, {:payload_too_large, _size}} ->
        respond(conn, 413, "payload too large")

      {:error, :payload_too_large} ->
        respond(conn, 413, "payload too large")

      {:error, {:invalid_key, _key}} ->
        respond(conn, 400, "delivery id too large")

      {:error, :queue_full} ->
        respond(conn, 503, "inbox full")

      {:error, :full} ->
        respond(conn, 503, "inbox full")

      {:error, reason} ->
        log_rejected(endpoint, "enqueue failed: #{inspect(reason)}")
        respond(conn, 500, "enqueue failed")
    end
  end

  defp read_body(conn, max) do
    case Plug.Conn.get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value, 10) do
          {length, ""} when length >= 0 and length <= max -> read_bounded_body(conn, max)
          {length, ""} when length > max -> {:error, :too_large, conn}
          _other -> {:error, :bad_length, conn}
        end

      [] ->
        read_chunked_body(conn, max, [], 0)

      _other ->
        {:error, :bad_length, conn}
    end
  end

  defp read_bounded_body(conn, max) do
    read_body_chunks(conn, max, [], 0, System.monotonic_time(:millisecond) + @recv_timeout)
  end

  defp read_chunked_body(conn, max, chunks, total),
    do:
      read_body_chunks(
        conn,
        max,
        chunks,
        total,
        System.monotonic_time(:millisecond) + @recv_timeout
      )

  defp read_body_chunks(conn, max, chunks, total, deadline) do
    case Plug.Conn.read_body(conn,
           length: max - total + 1,
           read_length: min(max - total + 1, 64_000),
           read_timeout: max(deadline - System.monotonic_time(:millisecond), 1)
         ) do
      {:ok, body, conn} when total + byte_size(body) <= max ->
        {:ok, IO.iodata_to_binary([chunks, body]), conn}

      {:ok, _body, conn} ->
        {:error, :too_large, conn}

      {:more, body, conn} when total + byte_size(body) <= max ->
        if System.monotonic_time(:millisecond) < deadline,
          do: read_body_chunks(conn, max, [chunks, body], total + byte_size(body), deadline),
          else: {:error, :bad_length, conn}

      {:more, _body, conn} ->
        {:error, :too_large, conn}

      {:error, _reason} ->
        {:error, :bad_length, conn}
    end
  end

  defp verify(%Endpoint{verify: verifier}, conn, body) do
    call_verifier(verifier, body, conn.req_headers)
  end

  defp identity(%Endpoint{identity: extractor}, conn),
    do: call_identity(extractor, conn.req_headers)

  defp call_verifier({module, opts}, body, headers) when is_atom(module) and is_list(opts) do
    result =
      cond do
        not Code.ensure_loaded?(module) -> {:error, :invalid_verify}
        function_exported?(module, :verify, 3) -> module.verify(body, headers, opts)
        function_exported?(module, :verify, 2) -> module.verify(body, headers)
        true -> {:error, :invalid_verify}
      end

    normalize_verifier_result(result)
  rescue
    UndefinedFunctionError -> {:error, :invalid_verify}
  end

  defp call_verifier({fun, opts}, body, headers)
       when is_function(fun, 3) and is_list(opts),
       do: normalize_verifier_result(fun.(body, headers, opts))

  defp call_verifier({fun, _opts}, body, headers)
       when is_function(fun, 2),
       do: normalize_verifier_result(fun.(body, headers))

  defp call_verifier(fun, body, headers) when is_function(fun, 2),
    do: normalize_verifier_result(fun.(body, headers))

  defp call_verifier(fun, body, headers) when is_function(fun, 3),
    do: normalize_verifier_result(fun.(body, headers, []))

  defp call_verifier(_verifier, _body, _headers), do: {:error, :invalid_verify}

  defp normalize_verifier_result(:ok), do: :ok
  defp normalize_verifier_result({:error, reason}), do: {:error, reason}
  defp normalize_verifier_result(_other), do: {:error, :invalid_verify}

  defp call_identity({module, opts}, headers) when is_atom(module) and is_list(opts) do
    result =
      cond do
        not Code.ensure_loaded?(module) -> {:error, :invalid_identity}
        function_exported?(module, :extract, 2) -> module.extract(headers, opts)
        function_exported?(module, :extract, 1) -> module.extract(headers)
        true -> {:error, :invalid_identity}
      end

    normalize_identity_result(result)
  rescue
    UndefinedFunctionError -> {:error, :invalid_identity}
  end

  defp call_identity({fun, opts}, headers)
       when is_function(fun, 2) and is_list(opts),
       do: normalize_identity_result(fun.(headers, opts))

  defp call_identity({fun, _opts}, headers)
       when is_function(fun, 1),
       do: normalize_identity_result(fun.(headers))

  defp call_identity(fun, headers) when is_function(fun, 1),
    do: normalize_identity_result(fun.(headers))

  defp call_identity(fun, headers) when is_function(fun, 2),
    do: normalize_identity_result(fun.(headers, []))

  defp call_identity(_extractor, _headers), do: {:error, :invalid_identity}

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
    case Enum.find(endpoints, &(&1.path == path)) do
      nil -> {:error, :not_found}
      endpoint -> {:ok, endpoint}
    end
  end

  defp route(endpoints, _method, path) do
    if Enum.any?(endpoints, &(&1.path == path)), do: {:error, :method}, else: {:error, :not_found}
  end

  defp build_endpoints(specs) when is_list(specs) and specs != [] do
    Enum.reduce_while(specs, {:ok, []}, fn
      spec, {:ok, acc} when is_map(spec) ->
        case build_endpoint(spec) do
          {:ok, endpoint} -> {:cont, {:ok, [endpoint | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _spec, _acc ->
        {:halt, {:error, :invalid_endpoints}}
    end)
    |> case do
      {:ok, endpoints} ->
        endpoints = Enum.reverse(endpoints)

        case endpoints |> Enum.map(& &1.path) |> duplicate_value() do
          nil -> {:ok, endpoints}
          path -> {:error, {:duplicate_endpoint_path, path}}
        end

      error ->
        error
    end
  end

  defp build_endpoints(_specs), do: {:error, :invalid_endpoints}

  defp build_endpoint(spec) do
    with {:ok, path} <- endpoint_path(spec),
         {:ok, {verify, legacy?}} <- endpoint_verify(Map.get(spec, :verify)),
         {:ok, identity} <- endpoint_identity(Map.get(spec, :identity), legacy?),
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

  defp endpoint_path(%{path: path}) when is_binary(path) and byte_size(path) > 1 do
    if String.starts_with?(path, "/") and not String.contains?(path, [<<0>>, "\n", "\r"]),
      do: {:ok, path},
      else: {:error, {:invalid_path, path}}
  end

  defp endpoint_path(_spec), do: {:error, :invalid_path}

  defp endpoint_verify({:hmac_sha256_base64, secret}) when is_binary(secret) and secret != "" do
    # Compatibility for the pre-generic adapter. New endpoints must choose a
    # verifier and identity explicitly; this path remains tied to the old
    # headers so existing integrations can migrate without changing wire data.
    {:ok, {{Alto.Ingress.HMAC, [secret: secret, header: "x-signature"]}, true}}
  end

  defp endpoint_verify({module, opts}) when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and
         (function_exported?(module, :verify, 3) or function_exported?(module, :verify, 2)),
       do: {:ok, {{module, opts}, false}},
       else: {:error, :invalid_verify}
  end

  defp endpoint_verify({fun, opts})
       when (is_function(fun, 2) or is_function(fun, 3)) and is_list(opts),
       do: {:ok, {{fun, opts}, false}}

  defp endpoint_verify(fun) when is_function(fun, 2) or is_function(fun, 3),
    do: {:ok, {fun, false}}

  defp endpoint_verify(_other), do: {:error, :invalid_verify}

  defp endpoint_identity(nil, true),
    do: {:ok, {Alto.Ingress.IdentityHeader, [header: "x-delivery-id"]}}

  defp endpoint_identity({module, opts}, false) when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and
         (function_exported?(module, :extract, 2) or function_exported?(module, :extract, 1)),
       do: {:ok, {module, opts}},
       else: {:error, :invalid_identity}
  end

  defp endpoint_identity({fun, opts}, false)
       when (is_function(fun, 1) or is_function(fun, 2)) and is_list(opts),
       do: {:ok, {fun, opts}}

  defp endpoint_identity(fun, false) when is_function(fun, 1) or is_function(fun, 2),
    do: {:ok, fun}

  defp endpoint_identity(nil, false), do: {:error, :invalid_identity}
  defp endpoint_identity(_other, _legacy), do: {:error, :invalid_identity}

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

  defp endpoint_on_event({:enqueue, queue})
       when not is_nil(queue) and (is_atom(queue) or is_pid(queue)),
       do: {:ok, {:enqueue, {Alto.Inboxes.Queue, queue: queue}}}

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
