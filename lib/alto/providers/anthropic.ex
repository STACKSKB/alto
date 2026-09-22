defmodule Alto.Providers.Anthropic do
  @moduledoc """
  Native Anthropic Messages adapter for text and client tools.

  Configure `{Alto.Providers.Anthropic, model: model_id, api_key: key}`. The
  Messages SSE response is consumed incrementally and bounded while received.
  Signed thinking blocks are preserved for subsequent tool turns. Typed image
  content is accepted only when the provider is explicitly configured with
  `supports_images: true`.

  Protocol: https://platform.claude.com/docs/en/api/messages/create
  """
  @behaviour Alto.Provider

  alias Alto.Content
  alias Alto.Providers.{HTTPOptions, StreamEnvelope}
  alias Alto.Providers.Anthropic.Stream

  @default_base_url "https://api.anthropic.com/v1"
  @config_schema List.insert_at(
                   HTTPOptions.stream_schema(),
                   1,
                   {:api_key,
                    [type: {:custom, HTTPOptions, :nonempty_string, []}, required: true]}
                 )
  @options ~w(max_tokens temperature top_p top_k stop_sequences tool_choice metadata output_config thinking cache_control)

  @impl true
  def describe(opts),
    do: %{
      protocol: :anthropic_messages,
      model: opts[:model],
      context_window: opts[:context_window],
      streaming: Keyword.get(opts, :streaming, true),
      tools: :client_tools,
      vision: Keyword.get(opts, :supports_images, false)
    }

  @impl true
  def stream(request, sink, opts) when is_map(request) and is_function(sink, 1) do
    with {:ok, config} <- config(opts),
         {:ok, body} <- request_body(request, config) do
      send_request(body, config, sink)
    end
  rescue
    error -> {:error, {:provider_exception, error, __STACKTRACE__}}
  end

  defp config(opts) do
    with {:ok, config} <-
           HTTPOptions.validate(
             HTTPOptions.endpoint_options(opts, @default_base_url, "/messages"),
             @config_schema
           ) do
      {:ok,
       Map.merge(config, %{
         prompt_cache: Keyword.get(opts, :prompt_cache, true),
         max_tokens: Keyword.get(opts, :max_tokens),
         thinking: Keyword.get(opts, :thinking),
         reasoning_effort: Keyword.get(opts, :reasoning_effort),
         streaming: Keyword.get(opts, :streaming, true),
         req_options: Keyword.get(opts, :req_options, [])
       })}
    end
  end

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
         :ok <- Alto.Context.Transcript.validate(request.messages),
         {systems, messages} <- Enum.split_with(request.messages, &(&1["role"] == "system")),
         {:ok, system_content} <- system_content(systems),
         {:ok, messages} <- Alto.Result.traverse(messages, &message(&1, config.supports_images)) do
      body =
        Map.merge(options, %{
          "model" => config.model,
          "max_tokens" => max_tokens,
          "stream" => config.streaming,
          "messages" => messages
        })

      body =
        if systems == [], do: body, else: Map.put(body, "system", system_content)

      body =
        if request[:tool_choice] == :none,
          do: Map.put(body, "tool_choice", %{"type" => "none"}),
          else: body

      tools =
        Enum.map(Map.get(request, :tools, []), fn %{"function" => tool} ->
          %{
            "name" => tool["name"],
            "description" => tool["description"] || "",
            "input_schema" => tool["parameters"]
          }
        end)

      {:ok,
       Alto.Providers.PromptCache.anthropic(
         if(tools == [], do: body, else: Map.put(body, "tools", tools)),
         config.prompt_cache
       )}
    else
      [_ | _] -> {:error, {:unsupported_anthropic_options, unsupported}}
      false -> {:error, :invalid_max_tokens}
      {:error, _} = error -> error
    end
  end

  defp system_content(messages) do
    messages
    |> Alto.Result.traverse(fn
      %{"content" => content} when is_binary(content) -> {:ok, content}
      _message -> {:error, :anthropic_system_content_must_be_text}
    end)
    |> case do
      {:ok, contents} -> {:ok, Enum.join(contents, "\n\n")}
      {:error, _} = error -> error
    end
  end

  defp message(%{"role" => "tool"} = message, supports_images) do
    with {:ok, content} <- anthropic_content(message["content"], supports_images) do
      {:ok,
       %{
         "role" => "user",
         "content" => [
           %{
             "type" => "tool_result",
             "tool_use_id" => message["tool_call_id"],
             "content" => content
           }
         ]
       }}
    end
  end

  defp message(%{"role" => role, "alto_anthropic_content" => content}, _supports_images)
       when role in ["user", "assistant"],
       do: {:ok, %{"role" => role, "content" => content}}

  defp message(%{"role" => role} = message, supports_images)
       when role in ["user", "assistant"] do
    with {:ok, content} <- anthropic_content(message["content"], supports_images) do
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

      {:ok,
       %{
         "role" => role,
         "content" => content ++ calls
       }}
    end
  end

  defp message(message, _supports_images),
    do: {:error, {:invalid_anthropic_message, message}}

  defp anthropic_content(value, supports_images) do
    case Content.decode_transcript(value) do
      :not_content when value in [nil, ""] ->
        {:ok, []}

      :not_content when is_binary(value) ->
        {:ok, [%{"type" => "text", "text" => value}]}

      {:ok, content} ->
        Content.map_images(content, supports_images, &anthropic_image/1)

      {:error, reason} ->
        {:error, {:invalid_multimodal_content, reason}}

      :not_content ->
        {:error, :invalid_anthropic_message_content}
    end
  end

  defp anthropic_image(%{"media_type" => media_type, "data" => data}) do
    %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
    }
  end

  defp send_request(body, config, sink) do
    headers = [
      {"accept", if(config.streaming, do: "text/event-stream", else: "application/json")},
      {"x-api-key", config.api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    StreamEnvelope.post(config, body, headers, Stream, sink)
  end
end
