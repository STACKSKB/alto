defmodule Alto.Contrib.Providers.OpenAICompatible do
  @moduledoc """
  Streaming Chat Completions adapter for OpenAI-compatible HTTP endpoints.

  Chat Completions is intentionally the first transport because it is the most
  widely implemented common protocol. Provider-native APIs belong in separate
  adapters rather than as conditionals in this module.
  """

  @behaviour Alto.Provider

  alias Alto.Content
  alias Alto.Contrib.Providers.HTTPOptions
  alias Alto.Contrib.Providers.StreamEnvelope
  alias Alto.Contrib.Providers.OpenAICompatible.Stream

  @default_base_url "https://openrouter.ai/api/v1"
  @config_schema HTTPOptions.stream_schema()
  @models_schema Keyword.take(@config_schema, [:endpoint, :timeout]) ++
                   [max_models_response_bytes: [type: :pos_integer, default: 8_000_000]]

  @impl true
  def describe(opts) do
    %{
      protocol: :openai_chat_completions,
      model: Keyword.get(opts, :model),
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      streaming: true,
      context_window: Keyword.get(opts, :context_window),
      tools: :function_calls,
      input_modalities: Alto.InputModalities.configured(opts),
      vision: "image" in Alto.InputModalities.configured(opts),
      files: "file" in Alto.InputModalities.configured(opts)
    }
  end

  @doc """
  Conservative byte-based context estimate for text-only Chat Completions runs.

  Uses the request codec so downloadable artifacts count as the text references
  sent to the model, while their full bytes remain in the saved transcript.
  Pass `&__MODULE__.estimate_text_context/1` to `Alto.Context.Window.new/1` as
  `:estimator`. This is not a tokenizer for image, audio or other media inputs;
  unsupported or invalid content retains its original size estimate and still
  undergoes normal validation before dispatch.
  """
  def estimate_text_context(%{messages: messages, tools: tools}) do
    projected =
      case provider_messages(messages, input_capabilities(["text"])) do
        {:ok, projected} -> projected
        {:error, _reason} -> messages
      end

    byte_size(JSON.encode!(%{messages: projected, tools: tools})) + 16 * length(projected) + 16
  end

  @doc "Check typed input using the wire codec without resolving credentials or sending a request."
  def check_input(%Content{} = content, opts) do
    case provider_message(
           %{"role" => "user", "content" => content.blocks},
           input_capabilities(Alto.InputModalities.configured(opts))
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def list_models(opts) do
    with {:ok, config} <- models_config(opts),
         {:ok, chunks} <-
           StreamEnvelope.request(
             config,
             config.headers,
             [method: :get, params: config.query],
             [],
             fn chunks, data -> {:ok, [data | chunks]} end
           ) do
      models_result(chunks)
    end
  rescue
    error -> {:error, {:provider_exception, error, __STACKTRACE__}}
  end

  @impl true
  def stream(request, sink, opts) when is_map(request) and is_function(sink, 1) do
    with {:ok, config} <- config(opts),
         do: Alto.Contrib.Usage.completion(request(config, request, sink))
  rescue
    error -> {:error, {:provider_exception, error, __STACKTRACE__}}
  end

  defp request(config, request, sink) do
    with {:ok, messages} <-
           provider_messages(
             Map.fetch!(request, :messages),
             input_capabilities(config.input_modalities)
           ) do
      body =
        request
        |> Map.get(:options, %{})
        |> Map.merge(%{
          "model" => config.model,
          "messages" => messages,
          "stream" => true
        })
        |> maybe_put_tools(Map.get(request, :tools, []))
        |> Alto.Contrib.Reasoning.apply_options(config.reasoning_format, config.reasoning_effort)
        |> Alto.Contrib.Providers.PromptCache.compatible(request, config)

      body =
        if request[:tool_choice] == :none, do: Map.put(body, "tool_choice", "none"), else: body

      StreamEnvelope.post(config, body, config.headers, Stream, sink)
    end
  end

  defp input_capabilities(modalities),
    do: %{
      images: "image" in modalities,
      audio: "audio" in modalities,
      video: "video" in modalities,
      files: "file" in modalities
    }

  defp provider_messages(messages, capabilities) do
    messages
    |> Enum.chunk_by(&match?(%{"role" => "tool"}, &1))
    |> Alto.Result.traverse(&provider_group(&1, capabilities))
    |> case do
      {:ok, groups} -> {:ok, List.flatten(groups)}
      error -> error
    end
  end

  defp provider_group([%{"role" => "tool"} | _] = messages, capabilities) do
    with {:ok, results} <-
           Alto.Result.traverse(messages, &openai_tool_message(&1, capabilities)) do
      {tools, images} = Enum.unzip(results)

      case List.flatten(images) do
        [] -> {:ok, tools}
        attachments -> {:ok, tools ++ [openai_attachment_message(attachments)]}
      end
    end
  end

  defp provider_group(messages, capabilities),
    do: Alto.Result.traverse(messages, &provider_message(&1, capabilities))

  defp openai_tool_message(message, capabilities) do
    message = Map.delete(message, "alto_anthropic_content")

    case Content.decode_transcript(Map.get(message, "content")) do
      :not_content ->
        {:ok, {message, []}}

      {:ok, content} ->
        with {:ok, blocks} <- Content.map_media(content, capabilities, &openai_media/1) do
          media = Enum.reject(blocks, &(&1["type"] == "text"))

          text =
            for(%{"type" => "text", "text" => text} <- blocks, do: text)
            |> Enum.join("\n")
            |> append_attachment_marker(message["tool_call_id"], media)

          {:ok,
           {Map.put(message, "content", text), Enum.map(media, &{message["tool_call_id"], &1})}}
        end

      {:error, reason} ->
        {:error, {:invalid_multimodal_content, reason}}
    end
  end

  defp append_attachment_marker(text, _call_id, []), do: text

  defp append_attachment_marker(text, call_id, media) do
    kind = if Enum.all?(media, &(&1["type"] == "image_url")), do: "Image", else: "File"
    marker = "[#{kind} attachment follows for tool call #{call_id}.]"
    if text == "", do: marker, else: text <> "\n" <> marker
  end

  defp openai_attachment_message(attachments) do
    content =
      Enum.flat_map(attachments, fn {call_id, image} ->
        [
          Content.text(
            "#{if(image["type"] == "image_url", do: "Image", else: "File")} result from tool call #{call_id}:"
          ),
          image
        ]
      end)

    %{"role" => "user", "content" => content}
  end

  defp provider_message(message, capabilities) when is_map(message) do
    message = message |> Map.delete("alto_anthropic_content") |> replayable_tool_arguments()

    case Content.decode_transcript(Map.get(message, "content")) do
      :not_content ->
        {:ok, message}

      {:ok, content} ->
        with {:ok, blocks} <- Content.map_media(content, capabilities, &openai_media/1) do
          {:ok, Map.put(message, "content", blocks)}
        end

      {:error, reason} ->
        {:error, {:invalid_multimodal_content, reason}}
    end
  end

  defp provider_message(message, _capabilities),
    do: {:error, {:invalid_provider_message, message}}

  # A failed tool call remains in the audit transcript verbatim. Some endpoints
  # reject malformed JSON even in historical calls, preventing the model from
  # seeing the tool error and correcting it. Wrap only the invalid wire value;
  # keep the call id, paired error result, and valid argument strings unchanged.
  # This representation is never passed to a tool for execution.
  defp replayable_tool_arguments(%{"role" => "assistant", "tool_calls" => calls} = message)
       when is_list(calls) do
    calls =
      Enum.map(calls, fn
        %{"function" => %{"arguments" => raw} = function} = call when is_binary(raw) ->
          case JSON.decode(raw) do
            {:ok, object} when is_map(object) ->
              call

            _ ->
              wrapped = JSON.encode!(%{"_alto_invalid_arguments" => raw})
              Map.put(call, "function", Map.put(function, "arguments", wrapped))
          end

        call ->
          call
      end)

    Map.put(message, "tool_calls", calls)
  end

  defp replayable_tool_arguments(message), do: message

  defp openai_media(%{"type" => "image", "media_type" => media_type, "data" => data}) do
    {:ok,
     %{"type" => "image_url", "image_url" => %{"url" => "data:#{media_type};base64,#{data}"}}}
  end

  defp openai_media(%{"type" => "file", "name" => name, "media_type" => media, "data" => data}) do
    encode_file(name, media, data)
  end

  defp encode_file(_name, "image/" <> _ = media, data),
    do: {:ok, %{"type" => "image_url", "image_url" => %{"url" => "data:#{media};base64,#{data}"}}}

  defp encode_file(_name, media, data)
       when media in ["audio/mpeg", "audio/mp3", "audio/wav", "audio/x-wav"] do
    format = if media in ["audio/mpeg", "audio/mp3"], do: "mp3", else: "wav"
    {:ok, %{"type" => "input_audio", "input_audio" => %{"data" => data, "format" => format}}}
  end

  defp encode_file(_name, "audio/" <> _ = media, _data),
    do: {:error, {:unsupported_audio_format, media}}

  defp encode_file(_name, "video/" <> _ = media, _data),
    do: {:error, {:unsupported_video_format, media}}

  defp encode_file(name, media, data) do
    {:ok,
     %{
       "type" => "file",
       "file" => %{"filename" => name, "file_data" => "data:#{media};base64,#{data}"}
     }}
  end

  defp models_result(chunks) do
    with body <- chunks |> Enum.reverse() |> IO.iodata_to_binary(),
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

  defp normalize_models(data) do
    Enum.flat_map(data, fn
      %{"id" => id} = model when is_binary(id) and id != "" ->
        normalized = %{
          id: id,
          name: string_value(model["name"], id),
          supported_parameters: string_list(model["supported_parameters"]),
          reasoning: if(is_map(model["reasoning"]), do: model["reasoning"]),
          efforts:
            if(is_list(model["supported_reasoning_efforts"]),
              do: model["supported_reasoning_efforts"]
            ),
          context_length: positive_value(model["context_length"]),
          input_modalities: Alto.Contrib.Providers.ModelMetadata.input_modalities(model)
        }

        [Map.reject(normalized, fn {_key, value} -> is_nil(value) end)]

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
    with {:ok, config} <-
           HTTPOptions.validate(
             HTTPOptions.endpoint_options(opts, @default_base_url, "/chat/completions"),
             @config_schema
           ) do
      {:ok,
       Map.merge(config, %{
         input_modalities: Alto.InputModalities.configured(opts),
         reasoning_effort: Keyword.get(opts, :reasoning_effort),
         reasoning_format: Alto.Contrib.Reasoning.format(opts),
         prompt_cache: Keyword.get(opts, :prompt_cache, true),
         headers:
           headers(opts, [{"accept", "text/event-stream"}, {"content-type", "application/json"}]),
         req_options: Keyword.get(opts, :req_options, [])
       })}
    end
  end

  defp models_config(opts) do
    with {:ok, config} <-
           HTTPOptions.validate(
             HTTPOptions.endpoint_options(opts, @default_base_url, "/models", :models_endpoint),
             @models_schema
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
