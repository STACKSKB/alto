defmodule Alto.Providers.OpenAICompatible.Stream do
  @moduledoc false

  alias Alto.Event

  @default_max_bytes 2_000_000

  defstruct content: [],
            calls: %{},
            usage: nil,
            error: nil,
            done?: false,
            bytes: 0,
            max_bytes: @default_max_bytes

  @type t :: %__MODULE__{
          content: iodata(),
          calls: map(),
          usage: map() | nil,
          error: term() | nil,
          done?: boolean(),
          bytes: non_neg_integer(),
          max_bytes: pos_integer()
        }

  @spec new(pos_integer()) :: t()
  def new(max_bytes \\ @default_max_bytes)
      when is_integer(max_bytes) and max_bytes > 0,
      do: %__MODULE__{max_bytes: max_bytes}

  @spec consume(t(), binary(), (Event.t() -> any())) :: t()
  def consume(%__MODULE__{} = state, "[DONE]", _sink), do: %{state | done?: true}

  def consume(%__MODULE__{} = state, payload, sink) when is_binary(payload) do
    bytes = state.bytes + byte_size(payload)

    if bytes > state.max_bytes do
      %{state | error: {:model_response_too_large, state.max_bytes}}
    else
      state = %{state | bytes: bytes}

      case JSON.decode(payload) do
        {:ok, %{"error" => error}} ->
          %{state | error: {:provider_error, error}}

        {:ok, decoded} when is_map(decoded) ->
          consume_chunk(state, decoded, sink)

        {:error, error} ->
          %{state | error: {:invalid_stream_json, Exception.message(error)}}

        {:ok, other} ->
          %{state | error: {:unexpected_stream_payload, other}}
      end
    end
  end

  @spec from_response(map(), (Event.t() -> any())) :: {:ok, t()} | {:error, term()}
  def from_response(%{"error" => error}, _sink), do: {:error, {:provider_error, error}}

  def from_response(%{"choices" => [%{"message" => message} | _]} = response, sink)
      when is_map(message) do
    content = Map.get(message, "content")

    if is_binary(content) and content != "" do
      sink.(Event.live(:model_delta, %{text: content}))
    end

    calls =
      message
      |> Map.get("tool_calls", [])
      |> Enum.with_index()
      |> Map.new(fn {call, index} -> {index, complete_call(call)} end)

    {:ok,
     %__MODULE__{
       content: if(is_binary(content), do: [content], else: []),
       calls: calls,
       usage: Map.get(response, "usage"),
       done?: true
     }}
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
         usage: state.usage
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
        case Map.get(fragment, "index") do
          index when is_integer(index) ->
            Map.update(calls, index, complete_call(fragment), &merge_call(&1, fragment))

          _missing when map_size(calls) == 0 ->
            %{0 => complete_call(fragment)}

          _missing ->
            # Index-less providers stream fragments for their most recent call;
            # without an index there is no other boundary to key on.
            Map.update(calls, Enum.max(Map.keys(calls)), complete_call(fragment), fn call ->
              merge_call(call, fragment)
            end)
        end
      end)

    %{state | calls: calls}
  end

  defp complete_call(call) do
    function = Map.get(call, "function", %{})

    %{
      id: Map.get(call, "id"),
      name: Map.get(function, "name"),
      argument_chunks: present(Map.get(function, "arguments"))
    }
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
    |> Enum.reduce_while({:ok, []}, fn {_index, call}, {:ok, acc} ->
      arguments_json = call.argument_chunks |> Enum.reverse() |> IO.iodata_to_binary()

      cond do
        not is_binary(call.id) or call.id == "" ->
          {:halt, {:error, :tool_call_missing_id}}

        not is_binary(call.name) or call.name == "" ->
          {:halt, {:error, {:tool_call_missing_name, call.id}}}

        true ->
          normalized = %{id: call.id, name: call.name, arguments_json: arguments_json}
          {:cont, {:ok, [normalized | acc]}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end
end
