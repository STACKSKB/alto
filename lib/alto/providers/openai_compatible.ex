defmodule Alto.Providers.OpenAICompatible do
  @moduledoc """
  Streaming Chat Completions adapter for OpenAI-compatible HTTP endpoints.

  Chat Completions is intentionally the first transport because it is the most
  widely implemented common protocol. Provider-native APIs belong in separate
  adapters rather than as conditionals in this module.
  """

  @behaviour Alto.Provider

  alias Alto.Content
  alias Alto.Providers.{HTTPOptions, StreamEnvelope}
  alias Alto.Providers.OpenAICompatible.Stream

  @default_base_url "https://openrouter.ai/api/v1"
  @config_schema HTTPOptions.stream_schema()
  @config_errors [
    model: :model_required,
    endpoint: {:value, :invalid_endpoint},
    timeout: {:value, :invalid_timeout},
    max_event_bytes: {:value, :invalid_max_event_bytes},
    max_response_bytes: {:value, :invalid_max_response_bytes},
    supports_images: {:value, :invalid_supports_images}
  ]
  @models_schema Keyword.take(@config_schema, [:endpoint, :timeout]) ++
                   [max_models_response_bytes: [type: :pos_integer, default: 8_000_000]]
  @models_errors [
    endpoint: {:value, :invalid_models_endpoint},
    timeout: {:value, :invalid_timeout},
    max_models_response_bytes: {:value, :invalid_max_models_response_bytes}
  ]
  @default_max_models_response_bytes 8_000_000
  @models_state_key :alto_openai_compatible_models

  @impl true
  def describe(opts) do
    %{
      protocol: :openai_chat_completions,
      model: Keyword.get(opts, :model),
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      streaming: true,
      context_window: Keyword.get(opts, :context_window),
      tools: :function_calls,
      vision: Keyword.get(opts, :supports_images, false)
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
         {:ok, completion} <- request(config, request, sink) do
      {:ok, completion}
    end
  rescue
    error -> {:error, {:provider_exception, error, __STACKTRACE__}}
  end

  defp request(config, request, sink) do
    with {:ok, messages} <-
           provider_messages(Map.fetch!(request, :messages), config.supports_images) do
      body =
        request
        |> Map.get(:options, %{})
        |> Map.merge(%{
          "model" => config.model,
          "messages" => messages,
          "stream" => true
        })
        |> maybe_put_tools(Map.get(request, :tools, []))
        |> Alto.Reasoning.apply_options(config.reasoning_format, config.reasoning_effort)
        |> Alto.Providers.PromptCache.compatible(request, config)

      body =
        if request[:tool_choice] == :none, do: Map.put(body, "tool_choice", "none"), else: body

      StreamEnvelope.post(config, body, config.headers, Stream, sink)
    end
  end

  defp provider_messages(messages, supports_images) do
    messages
    |> Enum.chunk_by(&match?(%{"role" => "tool"}, &1))
    |> Alto.Result.traverse(&provider_group(&1, supports_images))
    |> case do
      {:ok, groups} -> {:ok, List.flatten(groups)}
      error -> error
    end
  end

  defp provider_group([%{"role" => "tool"} | _] = messages, supports_images) do
    with {:ok, results} <-
           Alto.Result.traverse(messages, &openai_tool_message(&1, supports_images)) do
      {tools, images} = Enum.unzip(results)

      case List.flatten(images) do
        [] -> {:ok, tools}
        attachments -> {:ok, tools ++ [openai_attachment_message(attachments)]}
      end
    end
  end

  defp provider_group(messages, supports_images),
    do: Alto.Result.traverse(messages, &provider_message(&1, supports_images))

  defp openai_tool_message(message, supports_images) do
    message = Map.delete(message, "alto_anthropic_content")

    case Content.decode_transcript(Map.get(message, "content")) do
      :not_content ->
        {:ok, {message, []}}

      {:ok, content} ->
        images = Enum.filter(content.blocks, &match?(%Content.Image{}, &1))

        cond do
          images != [] and not supports_images ->
            {:error, :model_does_not_support_images}

          true ->
            text =
              content.blocks
              |> Enum.flat_map(fn
                %Content.Text{text: text} -> [text]
                %Content.Image{} -> []
              end)
              |> Enum.join("\n")
              |> append_attachment_marker(message["tool_call_id"], images)

            attachments = Enum.map(images, &{message["tool_call_id"], &1})
            {:ok, {Map.put(message, "content", text), attachments}}
        end

      {:error, reason} ->
        {:error, {:invalid_multimodal_content, reason}}
    end
  end

  defp append_attachment_marker(text, _call_id, []), do: text

  defp append_attachment_marker(text, call_id, _images) do
    marker = "[Image attachment follows for tool call #{call_id}.]"
    if text == "", do: marker, else: text <> "\n" <> marker
  end

  defp openai_attachment_message(attachments) do
    content =
      Enum.flat_map(attachments, fn {call_id, %Content.Image{media_type: media_type, data: data}} ->
        [
          %{"type" => "text", "text" => "Image result from tool call #{call_id}:"},
          %{
            "type" => "image_url",
            "image_url" => %{"url" => "data:#{media_type};base64,#{data}"}
          }
        ]
      end)

    %{"role" => "user", "content" => content}
  end

  defp provider_message(message, supports_images) when is_map(message) do
    message = Map.delete(message, "alto_anthropic_content")

    case Content.decode_transcript(Map.get(message, "content")) do
      :not_content ->
        {:ok, message}

      {:ok, content} ->
        with {:ok, blocks} <- openai_blocks(content.blocks, supports_images) do
          {:ok, Map.put(message, "content", blocks)}
        end

      {:error, reason} ->
        {:error, {:invalid_multimodal_content, reason}}
    end
  end

  defp provider_message(message, _supports_images),
    do: {:error, {:invalid_provider_message, message}}

  defp openai_blocks(blocks, supports_images) do
    Alto.Result.traverse(blocks, fn
      %Content.Text{text: text} ->
        {:ok, %{"type" => "text", "text" => text}}

      %Content.Image{} when not supports_images ->
        {:error, :model_does_not_support_images}

      %Content.Image{media_type: media_type, data: data} ->
        {:ok,
         %{
           "type" => "image_url",
           "image_url" => %{"url" => "data:#{media_type};base64,#{data}"}
         }}
    end)
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

    {:error, {:http_error, status, StreamEnvelope.decode_error_body(body)}}
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
          if is_map(model["reasoning"]),
            do: Map.put(normalized, :reasoning, model["reasoning"]),
            else: normalized

        normalized =
          if is_list(model["supported_reasoning_efforts"]),
            do: Map.put(normalized, :efforts, model["supported_reasoning_efforts"]),
            else: normalized

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

  defp maybe_put_tools(body, []), do: body

  defp maybe_put_tools(body, tools) do
    body
    |> Map.put("tools", tools)
    |> Map.put_new("tool_choice", "auto")
  end

  defp config(opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    endpoint =
      Keyword.get(opts, :endpoint, String.trim_trailing(base_url, "/") <> "/chat/completions")

    with {:ok, config} <-
           HTTPOptions.validate(
             Keyword.put(opts, :endpoint, endpoint),
             @config_schema,
             @config_errors
           ) do
      {:ok,
       Map.merge(config, %{
         reasoning_effort: Keyword.get(opts, :reasoning_effort),
         reasoning_format: Alto.Reasoning.format(opts),
         prompt_cache: Keyword.get(opts, :prompt_cache, true),
         headers:
           headers(opts, [{"accept", "text/event-stream"}, {"content-type", "application/json"}]),
         req_options: Keyword.get(opts, :req_options, [])
       })}
    end
  end

  defp models_config(opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    endpoint =
      Keyword.get(opts, :models_endpoint, String.trim_trailing(base_url, "/") <> "/models")

    with {:ok, config} <-
           HTTPOptions.validate(
             Keyword.put(opts, :endpoint, endpoint),
             @models_schema,
             @models_errors
           ) do
      {:ok,
       %{
         endpoint: config.endpoint,
         timeout: config.timeout,
         max_response_bytes: config.max_models_response_bytes,
         query: Keyword.get(opts, :model_query, []),
         headers: headers(opts, [{"accept", "application/json"}]),
         req_options: Keyword.get(opts, :req_options, [])
       }}
    end
  end

  defp headers(opts, headers) do
    (headers ++ [{"user-agent", "alto/0.1.0-dev"}])
    |> maybe_authorize(Keyword.get(opts, :api_key))
    |> Kernel.++(Keyword.get(opts, :headers, []))
  end

  defp maybe_authorize(headers, key) when is_binary(key) and key != "" do
    [{"authorization", "Bearer " <> key} | headers]
  end

  defp maybe_authorize(headers, _key), do: headers
end
