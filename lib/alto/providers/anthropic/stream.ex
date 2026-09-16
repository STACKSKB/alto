defmodule Alto.Providers.Anthropic.Stream do
  @moduledoc false

  alias Alto.Event

  @default_max_bytes 2_000_000
  @valid_stop_reasons ["end_turn", "tool_use", "stop_sequence"]

  defstruct content: [],
            reasoning: [],
            blocks: %{},
            block_order: [],
            usage: nil,
            stop_reason: nil,
            stop_sequence: nil,
            message_started?: false,
            message_stopped?: false,
            error: nil,
            bytes: 0,
            max_bytes: @default_max_bytes

  @type t :: %__MODULE__{
          content: iodata(),
          reasoning: iodata(),
          blocks: map(),
          block_order: [non_neg_integer()],
          usage: map() | nil,
          stop_reason: binary() | nil,
          message_stopped?: boolean(),
          error: term() | nil,
          bytes: non_neg_integer(),
          max_bytes: pos_integer()
        }

  @spec new(pos_integer()) :: t()
  def new(max_bytes \\ @default_max_bytes)
      when is_integer(max_bytes) and max_bytes > 0,
      do: %__MODULE__{max_bytes: max_bytes}

  @spec consume(t(), binary(), (Event.t() -> any())) :: t()
  def consume(%__MODULE__{error: error} = state, _payload, _sink) when not is_nil(error),
    do: state

  def consume(%__MODULE__{} = state, payload, sink) when is_binary(payload) do
    bytes = state.bytes + byte_size(payload)

    if bytes > state.max_bytes do
      %{state | bytes: bytes, error: {:model_response_too_large, state.max_bytes}}
    else
      state = %{state | bytes: bytes}

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
  end

  @spec from_response(map(), (Event.t() -> any())) :: {:ok, t()} | {:error, term()}
  def from_response(%{"content" => blocks, "stop_reason" => reason} = response, sink)
      when is_list(blocks) do
    state =
      Map.merge(new(), %{
        message_started?: true,
        message_stopped?: true,
        stop_reason: reason,
        stop_sequence: response["stop_sequence"],
        usage: response["usage"]
      })

    blocks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, fn {block, index}, {:ok, state} ->
      case put_response_block(state, index, block, sink) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
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
      {texts, thinking, calls, content} =
        Enum.reduce(blocks, {[], [], [], []}, fn block, {texts, thinking, calls, content} ->
          case block do
            %{"type" => "text", "text" => text} ->
              {[text | texts], thinking, calls, [block | content]}

            %{"type" => "thinking", "thinking" => text} ->
              {texts, [text | thinking], calls, [block | content]}

            %{"type" => "redacted_thinking"} ->
              {texts, thinking, calls, [block | content]}

            %{"type" => "tool_use"} ->
              {texts, thinking, [tool_call(block) | calls], [block | content]}
          end
        end)

      message = texts |> Enum.reverse() |> Enum.join()
      reasoning = thinking |> Enum.reverse() |> Enum.join("\n")
      calls = Enum.reverse(calls)

      {:ok,
       %{
         message: if(message == "", do: nil, else: message),
         tool_calls: calls,
         usage: state.usage,
         reasoning: reasoning,
         provider_fields:
           if(thinking == [],
             do: %{},
             else: %{"alto_anthropic_content" => Enum.reverse(content), "reasoning" => reasoning}
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
        stop_sequence: delta["stop_sequence"] || state.stop_sequence,
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
      block -> %{state | blocks: Map.put(state.blocks, index, Map.put(block, :stopped?, true))}
    end
  end

  defp consume_event(state, %{"type" => "error", "error" => error}, _sink),
    do: %{state | error: {:provider_error, error}}

  defp consume_event(state, %{"type" => type}, _sink),
    do: %{state | error: {:unexpected_stream_event, type}}

  defp new_block(%{"type" => "text"} = block) do
    text = block["text"] || ""

    if is_binary(text),
      do: {:ok, %{type: "text", text: text}},
      else: {:error, :unsupported_anthropic_content}
  end

  defp new_block(%{"type" => "thinking"} = block) do
    thinking = block["thinking"] || ""
    signature = block["signature"]

    if is_binary(thinking) and (is_nil(signature) or is_binary(signature)),
      do: {:ok, %{type: "thinking", text: thinking, signature: signature || ""}},
      else: {:error, :unsupported_anthropic_content}
  end

  defp new_block(%{"type" => "redacted_thinking", "data" => data}) when is_binary(data),
    do: {:ok, %{type: "redacted_thinking", data: data}}

  defp new_block(%{"type" => "tool_use", "id" => id, "name" => name} = block)
       when is_binary(id) and id != "" and is_binary(name) and name != "" do
    input = block["input"]

    if is_nil(input) or is_map(input),
      do: {:ok, %{type: "tool_use", id: id, name: name, input: input || %{}, chunks: []}},
      else: {:error, :unsupported_anthropic_content}
  end

  defp new_block(_), do: {:error, :unsupported_anthropic_content}

  defp put_block(state, index, block) do
    %{
      state
      | blocks: Map.put(state.blocks, index, block),
        block_order: state.block_order ++ [index]
    }
  end

  defp consume_delta(state, index, block, %{"type" => "text_delta", "text" => text}, sink)
       when block.type == "text" and is_binary(text) do
    sink.(Event.live(:model_delta, %{text: text}))
    update_block(state, index, %{block | text: block.text <> text})
  end

  defp consume_delta(state, index, block, %{"type" => "thinking_delta", "thinking" => text}, sink)
       when block.type == "thinking" and is_binary(text) do
    sink.(Event.live(:model_reasoning_delta, %{text: text}))
    update_block(state, index, %{block | text: block.text <> text})
  end

  defp consume_delta(
         state,
         index,
         block,
         %{"type" => "signature_delta", "signature" => signature},
         _sink
       )
       when block.type == "thinking" and is_binary(signature),
       do: update_block(state, index, %{block | signature: block.signature <> signature})

  defp consume_delta(
         state,
         index,
         block,
         %{"type" => "input_json_delta", "partial_json" => json},
         _sink
       )
       when block.type == "tool_use" and is_binary(json),
       do: update_block(state, index, %{block | chunks: [json | block.chunks]})

  defp consume_delta(state, _index, _block, _delta, _sink),
    do: %{state | error: :unsupported_anthropic_content}

  defp update_block(state, index, block),
    do: %{state | blocks: Map.put(state.blocks, index, block)}

  defp put_response_block(state, index, %{"type" => "text", "text" => text}, sink)
       when is_binary(text) do
    if text != "", do: sink.(Event.live(:model_delta, %{text: text}))
    {:ok, put_block(state, index, %{type: "text", text: text})}
  end

  defp put_response_block(
         state,
         index,
         %{"type" => "thinking", "thinking" => text, "signature" => signature},
         sink
       )
       when is_binary(text) and is_binary(signature) do
    if text != "", do: sink.(Event.live(:model_reasoning_delta, %{text: text}))
    {:ok, put_block(state, index, %{type: "thinking", text: text, signature: signature})}
  end

  defp put_response_block(state, index, %{"type" => "redacted_thinking", "data" => data}, _sink)
       when is_binary(data),
       do: {:ok, put_block(state, index, %{type: "redacted_thinking", data: data})}

  defp put_response_block(
         state,
         index,
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => input},
         _sink
       )
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(input),
       do:
         {:ok,
          put_block(state, index, %{
            type: "tool_use",
            id: id,
            name: name,
            input: input,
            chunks: []
          })}

  defp put_response_block(_state, _index, _block, _sink),
    do: {:error, :unsupported_anthropic_content}

  defp valid_final_response(%__MODULE__{message_started?: false}),
    do: {:error, :incomplete_model_response}

  defp valid_final_response(%__MODULE__{message_stopped?: false}),
    do: {:error, :incomplete_model_response}

  defp valid_final_response(%__MODULE__{stop_reason: reason}) when reason in @valid_stop_reasons,
    do: :ok

  defp valid_final_response(%__MODULE__{stop_reason: nil}),
    do: {:error, {:incomplete_model_response, nil}}

  defp valid_final_response(%__MODULE__{stop_reason: reason}),
    do: {:error, {:incomplete_model_response, reason}}

  defp finalize_blocks(state) do
    Enum.reduce_while(state.block_order, {:ok, []}, fn index, {:ok, acc} ->
      case finalize_block(Map.fetch!(state.blocks, index)) do
        {:ok, block} -> {:cont, {:ok, [block | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, blocks} -> {:ok, Enum.reverse(blocks)}
      error -> error
    end
  end

  defp finalize_block(%{type: "text", text: text}), do: {:ok, %{"type" => "text", "text" => text}}

  defp finalize_block(%{type: "thinking", text: text, signature: signature})
       when is_binary(text) and is_binary(signature) and signature != "",
       do: {:ok, %{"type" => "thinking", "thinking" => text, "signature" => signature}}

  defp finalize_block(%{type: "redacted_thinking", data: data}),
    do: {:ok, %{"type" => "redacted_thinking", "data" => data}}

  defp finalize_block(%{type: "tool_use", id: id, name: name, input: input, chunks: chunks}) do
    json =
      if chunks == [],
        do: JSON.encode!(input),
        else: chunks |> Enum.reverse() |> IO.iodata_to_binary()

    case JSON.decode(json) do
      {:ok, value} when is_map(value) ->
        {:ok, %{"type" => "tool_use", "id" => id, "name" => name, "input" => value}}

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
