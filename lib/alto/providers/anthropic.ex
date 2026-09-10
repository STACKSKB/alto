defmodule Alto.Providers.Anthropic do
  @moduledoc """
  Native Anthropic Messages adapter for text and client tools.

  Configure `{Alto.Providers.Anthropic, model: model_id, api_key: key}`. The
  response is bounded while received and emitted as one text event. This
  adapter reports `streaming: false`; extended thinking, multimodal content,
  server tools, and beta features are intentionally outside its contract.
  It never silently drops unsupported response blocks.

  Protocol: https://platform.claude.com/docs/en/api/messages/create
  """
  @behaviour Alto.Provider
  @state_key :alto_anthropic_body
  @options ~w(max_tokens temperature top_p top_k stop_sequences tool_choice metadata)

  @impl true
  def describe(opts),
    do: %{
      protocol: :anthropic_messages,
      model: opts[:model],
      context_window: opts[:context_window],
      streaming: false,
      tools: :client_tools
    }

  @impl true
  def stream(request, sink, opts) do
    with :ok <- validate_config(opts),
         {:ok, body} <- request_body(request, opts),
         {:ok, response} <- send_request(body, opts),
         {:ok, payload} <- response_payload(response),
         {:ok, completion} <- completion(payload) do
      if completion.message, do: sink.(Alto.Event.live(:model_delta, %{text: completion.message}))
      {:ok, completion}
    end
  rescue
    error -> {:error, {:invalid_anthropic_request, Exception.message(error)}}
  end

  defp validate_config(opts) do
    cond do
      not is_binary(opts[:model]) or opts[:model] == "" ->
        {:error, :model_required}

      not is_binary(opts[:api_key]) or opts[:api_key] == "" ->
        {:error, :api_key_required}

      not is_integer(Keyword.get(opts, :max_response_bytes, 2_000_000)) or
          Keyword.get(opts, :max_response_bytes, 2_000_000) < 1 ->
        {:error, :invalid_response_limit}

      true ->
        :ok
    end
  end

  defp request_body(request, opts) do
    options =
      Map.new(Map.get(request, :options, %{}), fn {key, value} -> {to_string(key), value} end)

    unsupported = Map.keys(options) -- @options
    max_tokens = Map.get(options, "max_tokens", Keyword.get(opts, :max_tokens, 4_096))

    with [] <- unsupported,
         true <- is_integer(max_tokens) and max_tokens > 0,
         :ok <- Alto.Context.Transcript.validate(request.messages) do
      {system, messages} = Enum.split_with(request.messages, &(&1["role"] == "system"))

      body =
        Map.merge(options, %{
          "model" => opts[:model],
          "max_tokens" => max_tokens,
          "stream" => false,
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

    %{"role" => role, "content" => text ++ calls}
  end

  defp send_request(body, opts) do
    limit = Keyword.get(opts, :max_response_bytes, 2_000_000)

    into = fn {:data, data}, {request, response} ->
      state = Req.Response.get_private(response, @state_key, %{chunks: [], bytes: 0, error: nil})
      bytes = state.bytes + byte_size(data)

      if bytes > limit do
        response =
          Req.Response.put_private(response, @state_key, %{
            state
            | error: {:model_response_too_large, limit}
          })

        {:halt, {request, response}}
      else
        response =
          Req.Response.put_private(response, @state_key, %{
            state
            | chunks: [data | state.chunks],
              bytes: bytes
          })

        {:cont, {request, response}}
      end
    end

    timeout = Keyword.get(opts, :timeout, 120_000)

    options = [
      url:
        String.trim_trailing(Keyword.get(opts, :base_url, "https://api.anthropic.com/v1"), "/") <>
          "/messages",
      headers: [
        {"x-api-key", opts[:api_key]},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ],
      body: JSON.encode!(body),
      into: into,
      raw: true,
      retry: false,
      receive_timeout: timeout,
      request_timeout: timeout
    ]

    case Req.post(Keyword.merge(Keyword.get(opts, :req_options, []), options)) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  end

  defp response_payload(response) do
    state = Req.Response.get_private(response, @state_key, %{chunks: [], error: nil})

    with nil <- state.error,
         {:ok, payload} <- JSON.decode(state.chunks |> Enum.reverse() |> IO.iodata_to_binary()) do
      if response.status in 200..299,
        do: {:ok, payload},
        else: {:error, {:http_error, response.status, payload}}
    else
      {:error, reason} -> {:error, {:invalid_response_json, reason}}
      reason -> {:error, reason}
    end
  end

  defp completion(%{"content" => blocks, "stop_reason" => reason} = payload)
       when is_list(blocks) do
    with true <- reason in ["end_turn", "tool_use", "stop_sequence"],
         {:ok, text, calls} <- Enum.reduce_while(blocks, {:ok, [], []}, &block/2) do
      message = text |> Enum.reverse() |> Enum.join()

      {:ok,
       %{
         message: if(message == "", do: nil, else: message),
         tool_calls: Enum.reverse(calls),
         usage: payload["usage"]
       }}
    else
      false -> {:error, {:incomplete_model_response, reason}}
      error -> error
    end
  end

  defp completion(_), do: {:error, :invalid_anthropic_response}

  defp block(%{"type" => "text", "text" => text}, {:ok, texts, calls}) when is_binary(text),
    do: {:cont, {:ok, [text | texts], calls}}

  defp block(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => input},
         {:ok, texts, calls}
       )
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(input),
       do:
         {:cont,
          {:ok, texts, [%{id: id, name: name, arguments_json: JSON.encode!(input)} | calls]}}

  defp block(_, _), do: {:halt, {:error, :unsupported_anthropic_content}}
end
