defmodule Alto.Persistence.Codec do
  @moduledoc """
  Bounded portable-term encoding for durable application data.

  By default, the codec accepts ordinary data terms only. Processes, ports, references,
  functions, and other runtime capabilities are rejected before encoding and
  after decoding. Decoding also requires that the ETF contain exactly one
  term; trailing bytes are never silently accepted.
  """

  @default_max_bytes 1_000_000
  @max_depth 64

  @doc "Check portability and ETF byte bounds without allocating an encoded value."
  @spec valid?(term(), keyword()) :: boolean()
  def valid?(term, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    valid_limit?(max_bytes) and :erlang.external_size(term) <= max_bytes and portable?(term, 0)
  rescue
    _ -> false
  end

  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def encode(term, opts \\ []) do
    if valid?(term, opts),
      do: {:ok, Base.encode64(:erlang.term_to_binary(term))},
      else: {:error, :not_portable_or_too_large}
  end

  @doc """
  Decode bounded ETF, rejecting runtime capabilities by default.

  A trusted `:validate` predicate may replace the portable-data policy for
  diagnostic stores. Framing, byte bounds and safe atom decoding always apply.
  """
  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, atom()}
  def decode(encoded, opts \\ [])

  def decode(encoded, opts) when is_binary(encoded) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    validate = Keyword.get(opts, :validate, &portable?(&1, 0))

    with true <- valid_limit?(max_bytes),
         # Base64 expands by 4/3; reject oversized input before ETF decoding.
         true <- byte_size(encoded) <= div(max_bytes * 4, 3) + 8,
         {:ok, binary} <- Base.decode64(encoded),
         <<131, tag, _::binary>> = binary,
         true <- tag != 80,
         true <- byte_size(binary) <= max_bytes,
         {term, used} <- :erlang.binary_to_term(binary, [:safe, :used]),
         true <- used == byte_size(binary),
         true <- validate.(term),
         true <- :erlang.external_size(term) <= max_bytes do
      {:ok, term}
    else
      _ -> {:error, :invalid_data}
    end
  rescue
    _ -> {:error, :invalid_data}
  end

  def decode(_, _), do: {:error, :invalid_data}

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
