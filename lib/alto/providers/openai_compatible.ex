defmodule Alto.Providers.OpenAICompatible do
  @moduledoc """
  Streaming Chat Completions adapter for OpenAI-compatible HTTP endpoints.

  Chat Completions is intentionally the first transport because it is the most
  widely implemented common protocol. Provider-native APIs belong in separate
  adapters rather than as conditionals in this module.
  """

  @behaviour Alto.Provider

  alias Alto.Providers.OpenAICompatible.SSE
  alias Alto.Providers.OpenAICompatible.Stream

  @default_base_url "https://openrouter.ai/api/v1"
  @default_timeout 120_000
  @default_max_event_bytes 1_000_000
  @default_max_response_bytes 2_000_000
  @default_max_models_response_bytes 8_000_000
  @state_key :alto_openai_compatible_stream
  @models_state_key :alto_openai_compatible_models

  @impl true
  def describe(opts) do
    %{
      protocol: :openai_chat_completions,
      model: Keyword.get(opts, :model),
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      streaming: true,
      context_window: Keyword.get(opts, :context_window),
      tools: :function_calls
    }
  end

  @impl true
  def list_models(opts) do
    with {:ok, config} <- models_config(opts),
         {:ok, response} <- models_request(config),
         {:ok, models} <- models_result(response) do
      {:ok, models}
    end
  rescue
    error -> {:error, {:provider_exception, error, __STACKTRACE__}}
  end

  @impl true
  def stream(request, sink, opts) when is_map(request) and is_function(sink, 1) do
    with {:ok, config} <- config(opts),
         {:ok, response} <- request(config, request, sink),
         {:ok, completion} <- response_result(response, sink) do
      {:ok, completion}
    end
  rescue
    error -> {:error, {:provider_exception, error, __STACKTRACE__}}
  end

  defp request(config, request, sink) do
    body =
      request
      |> Map.get(:options, %{})
      |> Map.merge(%{
        "model" => config.model,
        "messages" => Map.fetch!(request, :messages),
        "stream" => true
      })
      |> maybe_put_tools(Map.get(request, :tools, []))

    state = new_request_state(config.max_event_bytes, config.max_response_bytes)

    into = fn {:data, data}, {req, response} ->
      current = Req.Response.get_private(response, @state_key, state)
      next = consume_http_chunk(current, response.status, data, sink)
      response = Req.Response.put_private(response, @state_key, next)

      if next.error, do: {:halt, {req, response}}, else: {:cont, {req, response}}
    end

    options =
      [
        url: config.endpoint,
        body: JSON.encode!(body),
        headers: config.headers,
        into: into,
        raw: true,
        retry: false,
        receive_timeout: config.timeout,
        request_timeout: config.timeout
      ] ++ config.req_options

    case Req.post(options) do
      {:ok, response} -> {:ok, response}
      {:error, error} -> {:error, {:transport_error, error}}
    end
  end

  defp models_request(config) do
    state = %{chunks: [], bytes: 0, error: nil, limit: config.max_response_bytes}

    into = fn {:data, data}, {req, response} ->
      current = Req.Response.get_private(response, @models_state_key, state)
      next = consume_models_chunk(current, response.status, data)
      response = Req.Response.put_private(response, @models_state_key, next)

      if next.error, do: {:halt, {req, response}}, else: {:cont, {req, response}}
    end

    options =
      [
        url: config.endpoint,
        params: config.query,
        headers: config.headers,
        into: into,
        raw: true,
        retry: false,
        receive_timeout: config.timeout,
        request_timeout: config.timeout
      ] ++ config.req_options

    case Req.get(options) do
      {:ok, response} -> {:ok, response}
      {:error, error} -> {:error, {:transport_error, error}}
    end
  end

  defp models_result(%Req.Response{status: status} = response) when status in 200..299 do
    state = models_state(response)

    with nil <- state.error,
         body <- state.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
         {:ok, decoded} <- JSON.decode(body),
         %{"data" => data} when is_list(data) <- decoded,
         models when models != [] <- normalize_models(data) do
      {:ok, models}
    else
      {:error, error} -> {:error, {:invalid_models_response, error}}
      [] -> {:error, :empty_model_catalog}
      %{} -> {:error, :invalid_models_response_shape}
      reason -> {:error, reason}
    end
  end

  defp models_result(%Req.Response{status: status} = response) do
    state = models_state(response)
    body = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()

    detail =
      case JSON.decode(body) do
        {:ok, %{"error" => error}} -> error
        {:ok, decoded} -> decoded
        {:error, _error} -> body
      end

    {:error, {:http_error, status, detail}}
  end

  defp models_state(response) do
    Req.Response.get_private(response, @models_state_key, %{
      chunks: [],
      bytes: 0,
      error: nil,
      limit: @default_max_models_response_bytes
    })
  end

  defp consume_models_chunk(state, status, data) do
    limit = if status in 200..299, do: state.limit, else: min(state.limit, 64_000)
    size = state.bytes + byte_size(data)

    cond do
      size <= limit -> %{state | chunks: [data | state.chunks], bytes: size}
      status in 200..299 -> %{state | error: {:models_response_too_large, limit}}
      true -> state
    end
  end

  defp normalize_models(data) do
    Enum.flat_map(data, fn
      %{"id" => id} = model when is_binary(id) and id != "" ->
        normalized = %{
          id: id,
          name: string_value(model["name"], id),
          supported_parameters: string_list(model["supported_parameters"])
        }

        normalized =
          case positive_value(model["context_length"]) do
            nil -> normalized
            context_length -> Map.put(normalized, :context_length, context_length)
          end

        [normalized]

      _other ->
        []
    end)
  end

  defp string_value(value, _default) when is_binary(value) and value != "", do: value
  defp string_value(_value, default), do: default

  defp positive_value(value) when is_integer(value) and value > 0, do: value
  defp positive_value(_value), do: nil

  defp string_list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp string_list(_value), do: []

  defp response_result(%Req.Response{status: status} = response, sink)
       when status in 200..299 do
    state =
      Req.Response.get_private(
        response,
        @state_key,
        new_request_state(@default_max_event_bytes, @default_max_response_bytes)
      )

    with nil <- state.error,
         {:ok, completion_state} <- finish_stream(state, sink),
         {:ok, result} <- Stream.result(completion_state) do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
      reason -> {:error, reason}
    end
  end

  defp response_result(%Req.Response{status: status} = response, _sink) do
    state =
      Req.Response.get_private(
        response,
        @state_key,
        new_request_state(@default_max_event_bytes, @default_max_response_bytes)
      )

    body = state.error_body |> Enum.reverse() |> IO.iodata_to_binary()

    detail =
      case JSON.decode(body) do
        {:ok, %{"error" => error}} -> error
        {:ok, decoded} -> decoded
        {:error, _error} -> body
      end

    {:error, {:http_error, status, detail}}
  end

  defp finish_stream(state, sink) do
    case SSE.finish(state.sse) do
      {:ok, payloads} ->
        completion = Enum.reduce(payloads, state.completion, &Stream.consume(&2, &1, sink))
        {:ok, completion}

      {:raw, raw} ->
        with {:ok, response} <- JSON.decode(raw),
             {:ok, completion} <- Stream.from_response(response, sink) do
          {:ok, completion}
        else
          {:error, error} -> {:error, {:invalid_provider_response, error}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_http_chunk(state, status, data, sink) when status in 200..299 do
    case SSE.feed(state.sse, data) do
      {:ok, sse, payloads} ->
        completion = Enum.reduce(payloads, state.completion, &Stream.consume(&2, &1, sink))
        %{state | sse: sse, completion: completion, error: completion.error}

      {:error, reason} ->
        %{state | error: reason}
    end
  end

  defp consume_http_chunk(state, _status, data, _sink) do
    size = state.error_body_bytes + byte_size(data)

    if size <= state.max_error_body_bytes do
      %{state | error_body: [data | state.error_body], error_body_bytes: size}
    else
      state
    end
  end

  defp new_request_state(max_event_bytes, max_response_bytes) do
    %{
      sse: SSE.new(max_event_bytes),
      completion: Stream.new(max_response_bytes),
      error: nil,
      error_body: [],
      error_body_bytes: 0,
      max_error_body_bytes: 64_000
    }
  end

  defp maybe_put_tools(body, []), do: body

  defp maybe_put_tools(body, tools) do
    body
    |> Map.put("tools", tools)
    |> Map.put_new("tool_choice", "auto")
  end

  defp config(opts) do
    model = Keyword.get(opts, :model)
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    endpoint =
      Keyword.get(opts, :endpoint, String.trim_trailing(base_url, "/") <> "/chat/completions")

    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_event_bytes = Keyword.get(opts, :max_event_bytes, @default_max_event_bytes)
    max_response_bytes = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

    cond do
      not is_binary(model) or model == "" ->
        {:error, :model_required}

      not valid_endpoint?(endpoint) ->
        {:error, {:invalid_endpoint, endpoint}}

      not is_integer(timeout) or timeout <= 0 ->
        {:error, {:invalid_timeout, timeout}}

      not is_integer(max_event_bytes) or max_event_bytes <= 0 ->
        {:error, {:invalid_max_event_bytes, max_event_bytes}}

      not is_integer(max_response_bytes) or max_response_bytes <= 0 ->
        {:error, {:invalid_max_response_bytes, max_response_bytes}}

      true ->
        headers =
          [
            {"accept", "text/event-stream"},
            {"content-type", "application/json"},
            {"user-agent", "alto/0.1.0-dev"}
          ]
          |> maybe_authorize(Keyword.get(opts, :api_key))
          |> Kernel.++(Keyword.get(opts, :headers, []))

        {:ok,
         %{
           model: model,
           endpoint: endpoint,
           headers: headers,
           timeout: timeout,
           max_event_bytes: max_event_bytes,
           max_response_bytes: max_response_bytes,
           req_options: Keyword.get(opts, :req_options, [])
         }}
    end
  end

  defp models_config(opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    endpoint =
      Keyword.get(opts, :models_endpoint, String.trim_trailing(base_url, "/") <> "/models")

    timeout = Keyword.get(opts, :timeout, @default_timeout)

    max_response_bytes =
      Keyword.get(opts, :max_models_response_bytes, @default_max_models_response_bytes)

    cond do
      not valid_endpoint?(endpoint) ->
        {:error, {:invalid_models_endpoint, endpoint}}

      not is_integer(timeout) or timeout <= 0 ->
        {:error, {:invalid_timeout, timeout}}

      not is_integer(max_response_bytes) or max_response_bytes <= 0 ->
        {:error, {:invalid_max_models_response_bytes, max_response_bytes}}

      true ->
        headers =
          [{"accept", "application/json"}, {"user-agent", "alto/0.1.0-dev"}]
          |> maybe_authorize(Keyword.get(opts, :api_key))
          |> Kernel.++(Keyword.get(opts, :headers, []))

        {:ok,
         %{
           endpoint: endpoint,
           query: Keyword.get(opts, :model_query, []),
           headers: headers,
           timeout: timeout,
           max_response_bytes: max_response_bytes,
           req_options: Keyword.get(opts, :req_options, [])
         }}
    end
  end

  defp maybe_authorize(headers, key) when is_binary(key) and key != "" do
    [{"authorization", "Bearer " <> key} | headers]
  end

  defp maybe_authorize(headers, _key), do: headers

  defp valid_endpoint?(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _other ->
        false
    end
  end

  defp valid_endpoint?(_endpoint), do: false
end
