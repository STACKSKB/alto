defmodule Alto.Providers.OpenAICompatible.Stream do
  @moduledoc false

  alias Alto.Event

  defstruct content: [],
            reasoning: [],
            reasoning_fields: %{},
            reasoning_details: %{},
            reasoning_order: [],
            calls: %{},
            usage: nil,
            error: nil

  @type t :: %__MODULE__{
          content: iodata(),
          calls: map(),
          usage: map() | nil,
          error: term() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec consume(t(), binary(), (Event.t() -> any())) :: t()
  def consume(%__MODULE__{} = state, "[DONE]", _sink), do: state

  def consume(%__MODULE__{} = state, payload, sink) when is_binary(payload) do
    case JSON.decode(payload) do
      {:ok, %{"error" => error}} ->
        %{state | error: {:provider_error, error}}

      {:ok, decoded} when is_map(decoded) ->
        consume_chunk(state, decoded, sink)

      {:error, _error} ->
        %{state | error: {:invalid_stream_json, "Invalid JSON in provider stream"}}

      {:ok, other} ->
        %{state | error: {:unexpected_stream_payload, other}}
    end
  end

  @spec from_response(map(), (Event.t() -> any())) :: {:ok, t()} | {:error, term()}
  def from_response(%{"error" => error}, _sink), do: {:error, {:provider_error, error}}

  def from_response(%{"choices" => [%{"message" => message} | _]} = response, sink)
      when is_map(message) do
    calls =
      Enum.with_index(message["tool_calls"] || [], &Map.put(&1, "index", &2))

    state = consume_delta(new(), Map.put(message, "tool_calls", calls), sink)
    {:ok, %{state | usage: response["usage"]}}
  end

  def from_response(other, _sink), do: {:error, {:unexpected_response, other}}

  @spec result(t()) :: {:ok, map()} | {:error, term()}
  def result(%__MODULE__{error: error}) when not is_nil(error), do: {:error, error}

  def result(%__MODULE__{} = state) do
    with {:ok, tool_calls} <- finalize_calls(state.calls) do
      content = state.content |> Enum.reverse() |> IO.iodata_to_binary()

      {:ok,
       %{
         message: if(content == "", do: nil, else: content),
         tool_calls: tool_calls,
         usage: state.usage,
         reasoning: state.reasoning |> Enum.reverse() |> IO.iodata_to_binary(),
         provider_fields: reasoning_fields(state)
       }}
    end
  end

  defp consume_chunk(state, chunk, sink) do
    state = if is_map(chunk["usage"]), do: %{state | usage: chunk["usage"]}, else: state

    case chunk["choices"] do
      [%{"delta" => delta} | _] when is_map(delta) -> consume_delta(state, delta, sink)
      [] -> state
      nil -> state
      _other -> %{state | error: {:unexpected_stream_chunk, chunk}}
    end
  end

  defp consume_delta(state, delta, sink) do
    state = consume_reasoning(state, delta, sink)

    state =
      case delta["content"] do
        text when is_binary(text) and text != "" ->
          sink.(Event.live(:model_delta, %{text: text}))
          %{state | content: [text | state.content]}

        _other ->
          state
      end

    calls =
      Enum.reduce(delta["tool_calls"] || [], state.calls, fn fragment, calls ->
        # Index-less providers append to their most recent call.
        index = fragment["index"]
        index = if is_integer(index), do: index, else: Enum.max(Map.keys(calls), fn -> 0 end)
        call = Map.get(calls, index, %{id: nil, name: nil, argument_chunks: []})
        Map.put(calls, index, merge_call(call, fragment))
      end)

    %{state | calls: calls}
  end

  defp consume_reasoning(state, delta, sink) do
    text = Alto.Reasoning.text(delta)
    if text != "", do: sink.(Event.live(:model_reasoning_delta, %{text: text}))

    fields =
      Enum.reduce(["reasoning", "reasoning_content"], state.reasoning_fields, fn key, acc ->
        if is_binary(delta[key]),
          do: Map.update(acc, key, [delta[key]], &[delta[key] | &1]),
          else: acc
      end)

    {details, order} =
      (delta["reasoning_details"] || [])
      |> Enum.with_index()
      |> Enum.reduce({state.reasoning_details, state.reasoning_order}, fn {detail, fallback},
                                                                          {acc, order} ->
        key = detail["index"] || detail["id"] || fallback

        order = if Map.has_key?(acc, key), do: order, else: [key | order]

        updated =
          Map.update(acc, key, detail, fn previous ->
            Map.merge(previous, detail, fn key, left, right ->
              if key in ["text", "summary", "signature", "data"] and is_binary(left) and
                   is_binary(right),
                 do: left <> right,
                 else: if(is_nil(right), do: left, else: right)
            end)
          end)

        {updated, order}
      end)

    %{
      state
      | reasoning: if(text == "", do: state.reasoning, else: [text | state.reasoning]),
        reasoning_fields: fields,
        reasoning_details: details,
        reasoning_order: order
    }
  end

  defp reasoning_fields(state) do
    fields =
      Map.new(state.reasoning_fields, fn {key, parts} ->
        {key, parts |> Enum.reverse() |> IO.iodata_to_binary()}
      end)

    if map_size(state.reasoning_details) == 0,
      do: fields,
      else:
        Map.put(
          fields,
          "reasoning_details",
          Enum.map(Enum.reverse(state.reasoning_order), &Map.fetch!(state.reasoning_details, &1))
        )
  end

  defp merge_call(call, fragment) do
    function = Map.get(fragment, "function", %{})

    %{
      id: Map.get(fragment, "id") || call.id,
      name: Map.get(function, "name") || call.name,
      argument_chunks: present(Map.get(function, "arguments")) ++ call.argument_chunks
    }
  end

  defp present(value) when is_binary(value) and value != "", do: [value]
  defp present(_value), do: []

  defp finalize_calls(calls) do
    calls
    |> Enum.sort_by(fn {index, _call} -> index end)
    |> Alto.Result.traverse(fn {_index, call} ->
      arguments_json = call.argument_chunks |> Enum.reverse() |> IO.iodata_to_binary()

      cond do
        not is_binary(call.id) or call.id == "" ->
          {:error, :tool_call_missing_id}

        not is_binary(call.name) or call.name == "" ->
          {:error, {:tool_call_missing_name, call.id}}

        true ->
          {:ok, %{id: call.id, name: call.name, arguments_json: arguments_json}}
      end
    end)
  end
end
