defmodule Alto.Providers.Anthropic.Stream do
  @moduledoc false

  alias Alto.Event

  @valid_stop_reasons ["end_turn", "tool_use", "stop_sequence"]

  defstruct blocks: %{},
            block_order: [],
            usage: nil,
            stop_reason: nil,
            message_started?: false,
            message_stopped?: false,
            error: nil

  @type t :: %__MODULE__{
          blocks: map(),
          block_order: [non_neg_integer()],
          usage: map() | nil,
          stop_reason: binary() | nil,
          message_stopped?: boolean(),
          error: term() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec consume(t(), binary(), (Event.t() -> any())) :: t()
  def consume(%__MODULE__{error: error} = state, _payload, _sink) when not is_nil(error),
    do: state

  def consume(%__MODULE__{} = state, payload, sink) when is_binary(payload) do
    case JSON.decode(payload) do
      {:ok, %{"type" => _type} = event} ->
        consume_event(state, event, sink)

      {:ok, %{"error" => error}} ->
        %{state | error: {:provider_error, error}}

      {:ok, other} ->
        %{state | error: {:unexpected_stream_payload, other}}

      {:error, _error} ->
        %{state | error: {:invalid_stream_json, "Invalid JSON in provider stream"}}
    end
  end

  @spec from_response(map(), (Event.t() -> any())) :: {:ok, t()} | {:error, term()}
  def from_response(%{"content" => blocks, "stop_reason" => reason} = response, sink)
      when is_list(blocks) do
    state =
      Map.merge(new(), %{
        message_started?: true,
        message_stopped?: true,
        stop_reason: reason,
        usage: response["usage"]
      })

    blocks
    |> Enum.with_index()
    |> Alto.Result.reduce(state, fn {block, index}, state ->
      with {:ok, value} <- new_block(block),
           {:ok, _complete} <- finalize_block(value) do
        emit_block(value, sink)
        {:ok, put_block(state, index, value)}
      end
    end)
  end

  def from_response(%{"error" => error}, _sink), do: {:error, {:provider_error, error}}
  def from_response(_other, _sink), do: {:error, :invalid_anthropic_response}

  @spec result(t()) :: {:ok, map()} | {:error, term()}
  def result(%__MODULE__{error: error}) when not is_nil(error), do: {:error, error}

  def result(%__MODULE__{} = state) do
    with :ok <- valid_final_response(state),
         {:ok, blocks} <- finalize_blocks(state) do
      by_type = Enum.group_by(blocks, & &1["type"])
      message = Enum.map_join(Map.get(by_type, "text", []), & &1["text"])
      reasoning = Enum.map_join(Map.get(by_type, "thinking", []), "\n", & &1["thinking"])
      calls = Enum.map(Map.get(by_type, "tool_use", []), &tool_call/1)

      {:ok,
       %{
         message: if(message == "", do: nil, else: message),
         tool_calls: calls,
         usage: state.usage,
         reasoning: reasoning,
         provider_fields:
           if(Map.has_key?(by_type, "thinking"),
             do: %{"alto_anthropic_content" => blocks, "reasoning" => reasoning},
             else: %{}
           )
       }}
    end
  end

  defp consume_event(state, %{"type" => "message_start", "message" => message}, _sink) do
    %{state | message_started?: true, usage: message["usage"] || state.usage}
  end

  defp consume_event(state, %{"type" => "message_start"}, _sink),
    do: %{state | message_started?: true}

  defp consume_event(state, %{"type" => "ping"}, _sink), do: state

  defp consume_event(state, %{"type" => "message_stop"}, _sink),
    do: %{state | message_stopped?: true}

  defp consume_event(state, %{"type" => "message_delta", "delta" => delta} = event, _sink)
       when is_map(delta) do
    usage = merge_usage(state.usage, event["usage"])

    %{
      state
      | stop_reason: delta["stop_reason"] || state.stop_reason,
        usage: usage
    }
  end

  defp consume_event(state, %{"type" => "message_delta"}, _sink), do: state

  defp consume_event(
         state,
         %{"type" => "content_block_start", "index" => index, "content_block" => block},
         _sink
       )
       when is_integer(index) and is_map(block) do
    case new_block(block) do
      {:ok, value} -> put_block(state, index, value)
      {:error, reason} -> %{state | error: reason}
    end
  end

  defp consume_event(
         state,
         %{"type" => "content_block_delta", "index" => index, "delta" => delta},
         sink
       )
       when is_integer(index) and is_map(delta) do
    case Map.get(state.blocks, index) do
      nil -> %{state | error: {:unexpected_stream_chunk, :content_block_without_start}}
      block -> consume_delta(state, index, block, delta, sink)
    end
  end

  defp consume_event(state, %{"type" => "content_block_stop", "index" => index}, _sink)
       when is_integer(index) do
    case Map.get(state.blocks, index) do
      nil -> %{state | error: {:unexpected_stream_chunk, :content_block_without_start}}
      _block -> state
    end
  end

  defp consume_event(state, %{"type" => "error", "error" => error}, _sink),
    do: %{state | error: {:provider_error, error}}

  defp consume_event(state, %{"type" => type}, _sink),
    do: %{state | error: {:unexpected_stream_event, type}}

  defp new_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: {:ok, %{"type" => "text", "text" => text}}

  defp new_block(%{"type" => "thinking", "thinking" => thinking} = block)
       when is_binary(thinking) do
    signature = block["signature"]

    if is_nil(signature) or is_binary(signature),
      do: {:ok, %{"type" => "thinking", "thinking" => thinking, "signature" => signature || ""}},
      else: {:error, :unsupported_anthropic_content}
  end

  defp new_block(%{"type" => "redacted_thinking", "data" => data}) when is_binary(data),
    do: {:ok, %{"type" => "redacted_thinking", "data" => data}}

  defp new_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input})
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(input),
       do:
         {:ok, %{"type" => "tool_use", "id" => id, "name" => name, "input" => input, chunks: []}}

  defp new_block(_), do: {:error, :unsupported_anthropic_content}

  defp put_block(state, index, block) do
    %{
      state
      | blocks: Map.put(state.blocks, index, block),
        block_order: state.block_order ++ [index]
    }
  end

  @delta_fields %{
    "text_delta" => {"text", "text", :model_delta},
    "thinking_delta" => {"thinking", "thinking", :model_reasoning_delta},
    "signature_delta" => {"thinking", "signature", nil},
    "input_json_delta" => {"tool_use", "partial_json", nil}
  }

  defp consume_delta(state, index, block, delta, sink) do
    with {type, field, event} <- @delta_fields[delta["type"]],
         true <- block["type"] == type,
         text when is_binary(text) <- delta[field] do
      if event, do: sink.(Event.live(event, %{text: text}))

      updated =
        if field == "partial_json",
          do: %{block | chunks: [text | block.chunks]},
          else: Map.update!(block, field, &(&1 <> text))

      %{state | blocks: Map.put(state.blocks, index, updated)}
    else
      _ -> %{state | error: :unsupported_anthropic_content}
    end
  end

  defp emit_block(%{"type" => "text", "text" => text}, sink) when text != "" do
    sink.(Event.live(:model_delta, %{text: text}))
  end

  defp emit_block(%{"type" => "thinking", "thinking" => text}, sink) when text != "" do
    sink.(Event.live(:model_reasoning_delta, %{text: text}))
  end

  defp emit_block(_block, _sink), do: :ok

  defp valid_final_response(%__MODULE__{message_started?: false}),
    do: {:error, :incomplete_model_response}

  defp valid_final_response(%__MODULE__{message_stopped?: false}),
    do: {:error, :incomplete_model_response}

  defp valid_final_response(%__MODULE__{stop_reason: reason}) when reason in @valid_stop_reasons,
    do: :ok

  defp valid_final_response(%__MODULE__{stop_reason: reason}),
    do: {:error, {:incomplete_model_response, reason}}

  defp finalize_blocks(state) do
    Alto.Result.traverse(state.block_order, &finalize_block(Map.fetch!(state.blocks, &1)))
  end

  defp finalize_block(%{"type" => "text"} = block), do: {:ok, block}

  defp finalize_block(
         %{"type" => "thinking", "thinking" => text, "signature" => signature} = block
       )
       when is_binary(text) and is_binary(signature) and signature != "",
       do: {:ok, block}

  defp finalize_block(%{"type" => "redacted_thinking"} = block), do: {:ok, block}

  defp finalize_block(%{"type" => "tool_use", chunks: []} = block),
    do: {:ok, Map.delete(block, :chunks)}

  defp finalize_block(%{"type" => "tool_use", "id" => id, chunks: chunks} = block) do
    case chunks |> Enum.reverse() |> IO.iodata_to_binary() |> JSON.decode() do
      {:ok, value} when is_map(value) ->
        {:ok, block |> Map.delete(:chunks) |> Map.put("input", value)}

      _ ->
        {:error, {:invalid_tool_arguments, id}}
    end
  end

  defp finalize_block(_), do: {:error, :unsupported_anthropic_content}

  defp tool_call(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}),
    do: %{id: id, name: name, arguments_json: JSON.encode!(input)}

  defp merge_usage(nil, usage) when is_map(usage), do: usage
  defp merge_usage(usage, nil), do: usage
  defp merge_usage(left, right) when is_map(left) and is_map(right), do: Map.merge(left, right)
  defp merge_usage(left, _right), do: left
end
