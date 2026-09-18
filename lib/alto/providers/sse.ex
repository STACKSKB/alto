defmodule Alto.Providers.SSE do
  @moduledoc """
  ServerSentEvents.Parser with bounded wire accounting and raw JSON fallback.

  Original chunks go directly to the library; it owns parsing and CRLF handling.
  The counters scan line endings only to enforce a per-event wire limit across
  arbitrary chunk boundaries. A total response limit is enforced by StreamEnvelope.
  """
  alias ServerSentEvents.Parser

  @enforce_keys [:max_event_bytes]
  defstruct parser: nil,
            frame_bytes: 0,
            line_bytes: 0,
            prefix: "",
            cr?: false,
            raw_rev: [],
            raw_bytes: 0,
            sse?: false,
            max_event_bytes: 1_000_000

  def new(limit) when is_integer(limit) and limit > 0,
    do: %__MODULE__{max_event_bytes: limit, parser: Parser.new()}

  def feed(state, chunk) when is_binary(chunk) do
    with {:ok, next} <- account_wire(state, chunk),
         {:ok, next} <- capture_raw(next, chunk) do
      {events, parser} = Parser.parse(next.parser, chunk)
      {:ok, %{next | parser: parser}, Enum.map(events, & &1.data)}
    end
  end

  def finish(%{sse?: false, raw_rev: raw} = state) do
    if sse_field?(state.prefix),
      do: flush(state),
      else: {:raw, raw |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  def finish(state), do: flush(state)

  defp flush(state) do
    # Explicit provider EOF policy: deliver an unfinished final event.
    {events, _} = Parser.parse(state.parser, "\n\n")
    {:ok, Enum.map(events, & &1.data)}
  end

  defp account_wire(state, ""), do: {:ok, state}

  defp account_wire(%{cr?: true} = state, "\n" <> rest) do
    with {:ok, state} <- add_bytes(state, 1),
         do: account_wire(end_line(state), rest)
  end

  defp account_wire(%{cr?: true} = state, rest),
    do: account_wire(end_line(state), rest)

  defp account_wire(state, chunk) do
    case :binary.match(chunk, ["\r", "\n"]) do
      :nomatch ->
        add_text(state, chunk)

      {index, 1} ->
        <<text::binary-size(index), ending, rest::binary>> = chunk

        with {:ok, state} <- add_text(state, text),
             {:ok, state} <- add_bytes(state, 1) do
          next = if ending == ?\r, do: %{state | cr?: true}, else: end_line(state)
          account_wire(next, rest)
        end
    end
  end

  defp add_text(state, text) do
    with {:ok, state} <- add_bytes(state, byte_size(text)) do
      needed = max(6 - byte_size(state.prefix), 0)
      prefix = state.prefix <> binary_part(text, 0, min(needed, byte_size(text)))
      {:ok, %{state | line_bytes: state.line_bytes + byte_size(text), prefix: prefix}}
    end
  end

  defp add_bytes(state, bytes) do
    size = state.frame_bytes + bytes

    if size <= state.max_event_bytes,
      do: {:ok, %{state | frame_bytes: size}},
      else: {:error, {:sse_event_too_large, state.max_event_bytes}}
  end

  defp end_line(state) do
    sse? = state.sse? or sse_field?(state.prefix)

    %{
      state
      | line_bytes: 0,
        prefix: "",
        cr?: false,
        sse?: sse?,
        frame_bytes: if(state.line_bytes == 0, do: 0, else: state.frame_bytes)
    }
  end

  defp sse_field?(":" <> _), do: true

  defp sse_field?(prefix) do
    Enum.any?(["data", "event", "id", "retry"], fn field ->
      prefix == field or String.starts_with?(prefix, field <> ":")
    end)
  end

  defp capture_raw(%{sse?: true} = state, _chunk),
    do: {:ok, %{state | raw_rev: nil, raw_bytes: 0}}

  defp capture_raw(state, chunk) do
    size = state.raw_bytes + byte_size(chunk)

    if size <= state.max_event_bytes,
      do: {:ok, %{state | raw_rev: [chunk | state.raw_rev], raw_bytes: size}},
      else: {:error, {:sse_event_too_large, state.max_event_bytes}}
  end
end
