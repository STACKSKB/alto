defmodule Alto.Providers.Anthropic do
  @moduledoc """
  Native Anthropic Messages adapter for text and client tools.

  Configure `{Alto.Providers.Anthropic, model: model_id, api_key: key}`. The
  Messages SSE response is consumed incrementally and bounded while received.
  Signed thinking blocks are preserved for subsequent tool turns. Multimodal
  content, server tools, and beta features are intentionally outside its
  contract.

  Protocol: https://platform.claude.com/docs/en/api/messages/create
  """
  @behaviour Alto.Provider

  alias Alto.Providers.Anthropic.SSE
  alias Alto.Providers.Anthropic.Stream

  @default_base_url "https://api.anthropic.com/v1"
  @default_timeout 120_000
  @default_max_event_bytes 1_000_000
  @default_max_response_bytes 2_000_000
  @state_key :alto_anthropic_stream
  @options ~w(max_tokens temperature top_p top_k stop_sequences tool_choice metadata output_config thinking)

  @impl true
  def describe(opts),
    do: %{
      protocol: :anthropic_messages,
      model: opts[:model],
      context_window: opts[:context_window],
      streaming: Keyword.get(opts, :streaming, true),
      tools: :client_tools
    }

  @impl true
  def stream(request, sink, opts) when is_map(request) and is_function(sink, 1) do
    with {:ok, config} <- config(opts),
         {:ok, body} <- request_body(request, config),
         {:ok, response} <- send_request(body, config, sink),
         {:ok, completion} <- response_result(response, sink, config) do
      {:ok, completion}
    end
  rescue
    error -> {:error, {:invalid_anthropic_request, Exception.message(error)}}
  end

  defp config(opts) do
    model = Keyword.get(opts, :model)
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    endpoint = Keyword.get(opts, :endpoint, String.trim_trailing(base_url, "/") <> "/messages")
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_event_bytes = Keyword.get(opts, :max_event_bytes, @default_max_event_bytes)
    max_response_bytes = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

    cond do
      not is_binary(model) or model == "" ->
        {:error, :model_required}

      not is_binary(api_key) or api_key == "" ->
        {:error, :api_key_required}

      not valid_endpoint?(endpoint) ->
        {:error, {:invalid_endpoint, endpoint}}

      not is_integer(timeout) or timeout <= 0 ->
        {:error, {:invalid_timeout, timeout}}

      not is_integer(max_event_bytes) or max_event_bytes <= 0 ->
        {:error, {:invalid_max_event_bytes, max_event_bytes}}

      not is_integer(max_response_bytes) or max_response_bytes <= 0 ->
        # Keep the original adapter's public error for this existing limit;
        # max_event_bytes is the only new bound exposed by the SSE transport.
        {:error, :invalid_response_limit}

      true ->
        {:ok,
         %{
           model: model,
           api_key: api_key,
           endpoint: endpoint,
           timeout: timeout,
           max_event_bytes: max_event_bytes,
           max_response_bytes: max_response_bytes,
           max_tokens: Keyword.get(opts, :max_tokens),
           thinking: Keyword.get(opts, :thinking),
           reasoning_effort: Keyword.get(opts, :reasoning_effort),
           streaming: Keyword.get(opts, :streaming, true),
           req_options: Keyword.get(opts, :req_options, [])
         }}
    end
  end

  defp valid_endpoint?(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp valid_endpoint?(_), do: false

  defp request_body(request, config) do
    options =
      Map.new(Map.get(request, :options, %{}), fn {key, value} -> {to_string(key), value} end)

    options =
      if config.thinking, do: Map.put_new(options, "thinking", config.thinking), else: options

    options = Alto.Reasoning.apply_options(options, :anthropic, config.reasoning_effort)
    unsupported = Map.keys(options) -- @options
    max_tokens = Map.get(options, "max_tokens", config.max_tokens || 4_096)

    with [] <- unsupported,
         true <- is_integer(max_tokens) and max_tokens > 0,
         :ok <- Alto.Context.Transcript.validate(request.messages) do
      {system, messages} = Enum.split_with(request.messages, &(&1["role"] == "system"))

      body =
        Map.merge(options, %{
          "model" => config.model,
          "max_tokens" => max_tokens,
          "stream" => config.streaming,
          "messages" => Enum.map(messages, &message/1)
        })

      body =
        if system == [],
          do: body,
          else: Map.put(body, "system", Enum.map_join(system, "\n\n", & &1["content"]))

      tools =
        Enum.map(Map.get(request, :tools, []), fn %{"function" => tool} ->
          %{
            "name" => tool["name"],
            "description" => tool["description"] || "",
            "input_schema" => tool["parameters"]
          }
        end)

      {:ok, if(tools == [], do: body, else: Map.put(body, "tools", tools))}
    else
      [_ | _] -> {:error, {:unsupported_anthropic_options, unsupported}}
      false -> {:error, :invalid_max_tokens}
      {:error, _} = error -> error
    end
  end

  defp message(%{"role" => "tool"} = message),
    do: %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => message["tool_call_id"],
          "content" => message["content"]
        }
      ]
    }

  defp message(%{"role" => role} = message) when role in ["user", "assistant"] do
    text =
      case message["content"] do
        nil -> []
        "" -> []
        text when is_binary(text) -> [%{"type" => "text", "text" => text}]
      end

    calls =
      Enum.map(message["tool_calls"] || [], fn call ->
        input = JSON.decode!(call["function"]["arguments"])
        if not is_map(input), do: raise(ArgumentError, "tool input must be an object")

        %{
          "type" => "tool_use",
          "id" => call["id"],
          "name" => call["function"]["name"],
          "input" => input
        }
      end)

    %{
      "role" => role,
      "content" => Map.get(message, "alto_anthropic_content", text ++ calls)
    }
  end

  defp send_request(body, config, sink) do
    into = fn {:data, data}, {request, response} ->
      state = Req.Response.get_private(response, @state_key, new_request_state(config))
      next = consume_http_chunk(state, response.status, data, sink)
      response = Req.Response.put_private(response, @state_key, next)

      if next.error, do: {:halt, {request, response}}, else: {:cont, {request, response}}
    end

    options = [
      url: config.endpoint,
      headers: [
        {"accept", if(config.streaming, do: "text/event-stream", else: "application/json")},
        {"x-api-key", config.api_key},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ],
      body: JSON.encode!(body),
      into: into,
      raw: true,
      retry: false,
      receive_timeout: config.timeout,
      request_timeout: config.timeout
    ]

    case Req.post(Keyword.merge(config.req_options, options)) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  end

  defp new_request_state(config) do
    %{
      sse: SSE.new(config.max_event_bytes),
      completion: Stream.new(config.max_response_bytes),
      error: nil,
      error_body: [],
      error_body_bytes: 0,
      response_bytes: 0,
      max_response_bytes: config.max_response_bytes,
      max_error_body_bytes: min(config.max_response_bytes, 64_000)
    }
  end

  defp consume_http_chunk(state, status, data, sink) do
    response_bytes = state.response_bytes + byte_size(data)

    cond do
      response_bytes > state.max_response_bytes ->
        %{
          state
          | response_bytes: response_bytes,
            error: {:model_response_too_large, state.max_response_bytes}
        }

      status in 200..299 ->
        case SSE.feed(state.sse, data) do
          {:ok, sse, payloads} ->
            completion =
              Enum.reduce(payloads, state.completion, fn payload, acc ->
                Stream.consume(acc, payload, sink)
              end)

            %{
              state
              | sse: sse,
                completion: completion,
                response_bytes: response_bytes,
                error: completion.error
            }

          {:error, reason} ->
            %{state | response_bytes: response_bytes, error: reason}
        end

      true ->
        error_body_bytes = state.error_body_bytes + byte_size(data)

        if error_body_bytes <= state.max_error_body_bytes,
          do: %{
            state
            | error_body: [data | state.error_body],
              error_body_bytes: error_body_bytes,
              response_bytes: response_bytes
          },
          else: %{state | response_bytes: response_bytes}
    end
  end

  defp response_result(%Req.Response{status: status} = response, sink, config)
       when status in 200..299 do
    state = Req.Response.get_private(response, @state_key, new_request_state(config))

    with nil <- state.error,
         {:ok, completion_state} <- finish_stream(state, sink),
         {:ok, result} <- Stream.result(completion_state) do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
      reason -> {:error, reason}
    end
  end

  defp response_result(%Req.Response{status: status} = response, _sink, config) do
    state = Req.Response.get_private(response, @state_key, new_request_state(config))

    if state.error do
      {:error, state.error}
    else
      response_error(state, status)
    end
  end

  defp response_error(state, status) do
    body = state.error_body |> Enum.reverse() |> IO.iodata_to_binary()

    detail =
      case JSON.decode(body) do
        {:ok, %{"error" => error}} -> error
        {:ok, decoded} -> decoded
        {:error, _} -> body
      end

    {:error, {:http_error, status, detail}}
  end

  defp finish_stream(state, sink) do
    case SSE.finish(state.sse) do
      {:ok, payloads} ->
        completion =
          Enum.reduce(payloads, state.completion, fn payload, acc ->
            Stream.consume(acc, payload, sink)
          end)

        {:ok, completion}

      {:raw, raw} ->
        case JSON.decode(raw) do
          {:ok, response} -> Stream.from_response(response, sink)
          {:error, error} -> {:error, {:invalid_provider_response, error}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
