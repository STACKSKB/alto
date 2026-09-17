defmodule Alto.Providers.SSE do
  @moduledoc """
  Bounded provider response framing around ServerSentEvents.Parser.

  The envelope owns raw JSON fallback, wire byte limits and EOF flushing.
  The library owns SSE field interpretation and data assembly. Lines are
  normalized only after byte accounting, preserving split CRLF and UTF-8.
  """

  @enforce_keys [:max_event_bytes]
  defstruct buffer: "",
            parser: nil,
            frame_bytes: 0,
            raw_rev: [],
            raw_bytes: 0,
            sse?: false,
            max_event_bytes: 1_000_000

  @type t :: %__MODULE__{
          buffer: binary(),
          parser: ServerSentEvents.Parser.t(),
          frame_bytes: non_neg_integer(),
          raw_rev: [binary()] | nil,
          raw_bytes: non_neg_integer(),
          sse?: boolean(),
          max_event_bytes: pos_integer()
        }

  @spec new(pos_integer()) :: t()
  def new(max_event_bytes) when is_integer(max_event_bytes) and max_event_bytes > 0,
    do: %__MODULE__{max_event_bytes: max_event_bytes, parser: ServerSentEvents.Parser.new()}

  @spec feed(t(), binary()) :: {:ok, t(), [binary()]} | {:error, term()}
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    state = capture_raw(state, chunk)

    with {:ok, state, payloads} <- consume_lines(state, state.buffer <> chunk, [], false),
         :ok <- validate_pending(state) do
      {:ok, state, Enum.reverse(payloads)}
    end
  end

  @spec finish(t()) :: {:ok, [binary()]} | {:raw, binary()} | {:error, term()}
  def finish(%__MODULE__{sse?: false, raw_rev: raw_rev}),
    do: {:raw, raw_rev |> Enum.reverse() |> IO.iodata_to_binary()}

  def finish(%__MODULE__{} = state) do
    with {:ok, state, payloads} <- consume_lines(state, state.buffer, [], true),
         {:ok, state, payloads} <- consume_final_line(state, payloads),
         :ok <- validate_pending(state) do
      {_state, payloads} = dispatch_frame(state, payloads)
      {:ok, Enum.reverse(payloads)}
    end
  end

  defp consume_lines(state, binary, payloads, final?) do
    case take_line(binary, final?) do
      {:line, line, rest, ending_bytes} ->
        with {:ok, state} <- account_line(state, line, ending_bytes) do
          {state, payloads} = consume_line(state, line, payloads)
          consume_lines(state, rest, payloads, final?)
        end

      :more ->
        {:ok, %{state | buffer: binary}, payloads}
    end
  end

  defp take_line(binary, final?) do
    case :binary.match(binary, ["\r", "\n"]) do
      :nomatch ->
        :more

      {index, 1} ->
        ending = binary_part(binary, index, 1)

        if ending == "\r" and index + 1 == byte_size(binary) and not final? do
          :more
        else
          following = index + 1

          {ending_bytes, rest_start} =
            if ending == "\r" and following < byte_size(binary) and
                 binary_part(binary, following, 1) == "\n" do
              {2, following + 1}
            else
              {1, following}
            end

          line = binary_part(binary, 0, index)
          rest = binary_part(binary, rest_start, byte_size(binary) - rest_start)
          {:line, line, rest, ending_bytes}
        end
    end
  end

  defp account_line(state, line, ending_bytes) do
    bytes = state.frame_bytes + byte_size(line) + ending_bytes

    if bytes <= state.max_event_bytes,
      do: {:ok, %{state | frame_bytes: bytes, buffer: ""}},
      else: {:error, {:sse_event_too_large, state.max_event_bytes}}
  end

  defp consume_line(state, line, payloads) do
    state = if sse_line?(line), do: %{state | sse?: true, raw_rev: nil, raw_bytes: 0}, else: state
    {events, parser} = ServerSentEvents.Parser.parse(state.parser, line <> "\n")
    state = %{state | parser: parser, frame_bytes: if(line == "", do: 0, else: state.frame_bytes)}
    {state, Enum.reverse(Enum.map(events, & &1.data), payloads)}
  end

  defp sse_line?(":" <> _), do: true

  defp sse_line?(line) do
    Enum.any?(["data", "event", "id", "retry"], fn field ->
      line == field or String.starts_with?(line, field <> ":")
    end)
  end

  defp dispatch_frame(state, payloads), do: consume_line(state, "", payloads)

  defp consume_final_line(%{buffer: ""} = state, payloads), do: {:ok, state, payloads}

  defp consume_final_line(state, payloads) do
    line = state.buffer

    with {:ok, state} <- account_line(state, line, 0) do
      {state, payloads} = consume_line(state, line, payloads)
      {:ok, %{state | buffer: ""}, payloads}
    end
  end

  defp capture_raw(%{raw_rev: nil} = state, _chunk), do: state

  defp capture_raw(state, chunk),
    do: %{state | raw_rev: [chunk | state.raw_rev], raw_bytes: state.raw_bytes + byte_size(chunk)}

  defp validate_pending(state) do
    pending_bytes = state.frame_bytes + byte_size(state.buffer)

    cond do
      pending_bytes > state.max_event_bytes ->
        {:error, {:sse_event_too_large, state.max_event_bytes}}

      is_list(state.raw_rev) and state.raw_bytes > state.max_event_bytes ->
        {:error, {:sse_event_too_large, state.max_event_bytes}}

      true ->
        :ok
    end
  end
end
