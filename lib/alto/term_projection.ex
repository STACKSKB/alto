defmodule Alto.TermProjection do
  @moduledoc "Bounded, portable JSON projections of runtime terms."
  @max_inspect_bytes 1_000

  @doc """
  The wire encoding for Elixir terms, per the protocol contract. Lossy but stable:
  tuples become `{"$tuple": [...]}` and unencodable terms become a bounded
  `inspect/1` string. Applied after the host's own bounds, never instead of
  them.
  """
  @spec encode_term(term()) :: term()
  def encode_term(term)
      when is_binary(term) or is_integer(term) or is_float(term) or is_boolean(term) or
             is_nil(term),
      do: term

  def encode_term(atom) when is_atom(atom), do: Atom.to_string(atom)

  # Structs are maps but not Enumerable; encode them as their field maps.
  def encode_term(%_{} = struct), do: encode_term(Map.from_struct(struct))

  def encode_term(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {encode_key(key), encode_term(value)} end)

  def encode_term(list) when is_list(list), do: encode_list(list)

  def encode_term(tuple) when is_tuple(tuple),
    do: %{"$tuple" => encode_term(Tuple.to_list(tuple))}

  def encode_term(other), do: %{"$inspect" => bounded_inspect(other)}

  # Walks improper lists too: a term that would crash the encoder must not
  # take the connection process down with it.
  defp encode_list([head | tail]), do: [encode_term(head) | encode_list(tail)]
  defp encode_list([]), do: []
  defp encode_list(other), do: [encode_term(other)]

  @doc false
  def encode_key(key) when is_atom(key), do: Atom.to_string(key)
  def encode_key(key) when is_binary(key), do: key
  def encode_key(key) when is_integer(key), do: Integer.to_string(key)
  def encode_key(key), do: bounded_inspect(key)

  defp bounded_inspect(term) do
    inspect(term, pretty: false, limit: 50, printable_limit: @max_inspect_bytes)
    |> Alto.Text.truncate(@max_inspect_bytes, "…")
  end
end
