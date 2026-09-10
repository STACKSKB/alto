defmodule Alto.Providers.OpenAICompatible.SSE do
  @moduledoc false

  @enforce_keys [:max_event_bytes]
  defstruct buffer: "",
            data_lines_rev: [],
            frame_bytes: 0,
            raw_rev: [],
            raw_bytes: 0,
            sse?: false,
            max_event_bytes: 1_000_000

  @type t :: %__MODULE__{
          buffer: binary(),
          data_lines_rev: [binary()],
          frame_bytes: non_neg_integer(),
          raw_rev: [binary()] | nil,
          raw_bytes: non_neg_integer(),
          sse?: boolean(),
          max_event_bytes: pos_integer()
        }

  @spec new(pos_integer()) :: t()
  def new(max_event_bytes) when is_integer(max_event_bytes) and max_event_bytes > 0 do
    %__MODULE__{max_event_bytes: max_event_bytes}
  end

  @spec feed(t(), binary()) :: {:ok, t(), [binary()]} | {:error, term()}
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    state = capture_raw(state, chunk)

    with {:ok, state, payloads} <- consume_lines(state, state.buffer <> chunk, [], false),
         :ok <- validate_pending(state) do
      {:ok, state, Enum.reverse(payloads)}
    end
  end

  @spec finish(t()) :: {:ok, [binary()]} | {:raw, binary()} | {:error, term()}
  def finish(%__MODULE__{sse?: false, raw_rev: raw_rev}) do
    {:raw, raw_rev |> Enum.reverse() |> IO.iodata_to_binary()}
  end

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

    if bytes <= state.max_event_bytes do
      {:ok, %{state | frame_bytes: bytes, buffer: ""}}
    else
      {:error, {:sse_event_too_large, state.max_event_bytes}}
    end
  end

  defp consume_line(state, "", payloads), do: dispatch_frame(state, payloads)

  defp consume_line(state, line, payloads) do
    case data_value(line) do
      {:ok, value} ->
        state = mark_sse(state)
        {%{state | data_lines_rev: [value | state.data_lines_rev]}, payloads}

      :not_data ->
        state = if sse_control_line?(line), do: mark_sse(state), else: state
        {state, payloads}
    end
  end

  defp data_value("data"), do: {:ok, ""}
  defp data_value("data:" <> value), do: {:ok, remove_optional_space(value)}
  defp data_value(_line), do: :not_data

  defp remove_optional_space(" " <> value), do: value
  defp remove_optional_space(value), do: value

  defp sse_control_line?(":" <> _comment), do: true

  defp sse_control_line?(line) do
    Enum.any?(["event", "id", "retry"], fn field ->
      line == field or :binary.match(line, field <> ":") == {0, byte_size(field) + 1}
    end)
  end

  defp mark_sse(state), do: %{state | sse?: true, raw_rev: nil, raw_bytes: 0}

  defp dispatch_frame(%{data_lines_rev: []} = state, payloads) do
    {%{state | frame_bytes: 0}, payloads}
  end

  defp dispatch_frame(state, payloads) do
    payload = state.data_lines_rev |> Enum.reverse() |> Enum.join("\n")
    {%{state | data_lines_rev: [], frame_bytes: 0}, [payload | payloads]}
  end

  defp consume_final_line(%{buffer: ""} = state, payloads), do: {:ok, state, payloads}

  defp consume_final_line(state, payloads) do
    line = state.buffer

    with {:ok, state} <- account_line(state, line, 0) do
      {state, payloads} = consume_line(state, line, payloads)
      {:ok, %{state | buffer: ""}, payloads}
    end
  end

  defp capture_raw(%{raw_rev: nil} = state, _chunk), do: state

  defp capture_raw(state, chunk) do
    %{state | raw_rev: [chunk | state.raw_rev], raw_bytes: state.raw_bytes + byte_size(chunk)}
  end

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
