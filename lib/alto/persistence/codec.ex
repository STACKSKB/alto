defmodule Alto.Persistence.Codec do
  @moduledoc """
  Bounded portable-term encoding for durable application data.

  The codec accepts ordinary data terms only. Processes, ports, references,
  functions, and other runtime capabilities are rejected before encoding and
  after decoding. Decoding also requires that the ETF contain exactly one
  term; trailing bytes are never silently accepted.
  """

  @default_max_bytes 1_000_000
  @max_depth 64

  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def encode(term, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with true <- valid_limit?(max_bytes),
         true <- portable?(term, 0),
         true <- :erlang.external_size(term) <= max_bytes,
         binary <- :erlang.term_to_binary(term),
         true <- byte_size(binary) <= max_bytes do
      {:ok, Base.encode64(binary)}
    else
      false -> {:error, :not_portable_or_too_large}
    end
  rescue
    _ -> {:error, :not_portable_or_too_large}
  end

  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, atom()}
  def decode(encoded, opts \\ [])

  def decode(encoded, opts) when is_binary(encoded) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with true <- valid_limit?(max_bytes),
         {:ok, binary} <- decode_base64(encoded, max_bytes),
         <<131, tag, _::binary>> = binary,
         true <- tag != 80,
         true <- byte_size(binary) <= max_bytes,
         {term, used} <- :erlang.binary_to_term(binary, [:safe, :used]),
         true <- used == byte_size(binary),
         true <- portable?(term, 0),
         true <- :erlang.external_size(term) <= max_bytes do
      {:ok, term}
    else
      _ -> {:error, :invalid_data}
    end
  rescue
    _ -> {:error, :invalid_data}
  end

  def decode(_, _), do: {:error, :invalid_data}

  defp decode_base64(encoded, max_bytes) do
    # Base64 expands by 4/3. Reject oversized input before allocating ETF
    # validation work, while allowing the small padding variation.
    if byte_size(encoded) <= div(max_bytes * 4, 3) + 8 do
      case Base.decode64(encoded) do
        {:ok, binary} -> {:ok, binary}
        :error -> {:error, :invalid_data}
      end
    else
      {:error, :invalid_data}
    end
  end

  defp portable?(_, depth) when depth > @max_depth, do: false
  defp portable?(value, _) when is_atom(value) or is_binary(value) or is_number(value), do: true

  defp portable?(value, depth) when is_list(value),
    do: Enum.all?(value, &portable?(&1, depth + 1))

  defp portable?(value, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> portable?(depth + 1)

  defp portable?(value, depth) when is_map(value),
    do:
      Enum.all?(Map.to_list(value), fn {key, item} ->
        portable?(key, depth + 1) and portable?(item, depth + 1)
      end)

  # This final clause deliberately excludes pids, ports, references,
  # functions, and non-byte bitstrings.
  defp portable?(_, _), do: false

  defp valid_limit?(value), do: is_integer(value) and value > 0
end
