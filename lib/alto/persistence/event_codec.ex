defmodule Alto.Persistence.EventCodec do
  @moduledoc """
  Versioned JSON storage codec for session event bodies and outcomes.

  A single typed tree retains atoms, tuples, map keys and structs while keeping
  text payloads as ordinary JSON strings. `decode/2` restores exact terms using
  existing atoms only; `project/2` produces the front-end protocol's lossy shape
  without resolving atoms or loading modules. Both readers are bounded.

  Lists are tagged too, so user data cannot impersonate a type marker. Opaque
  runtime values retain bounded ETF plus the protocol's small display projection;
  they use the existing persistence codec and its validation policy on decode.
  This is deliberately session-specific, not a replacement for the ETF codec used
  by checkpoints and operation logs.
  """

  alias Alto.Persistence.Codec
  @default_max_bytes 16_000_000
  @max_depth 64

  @type envelope :: %{required(String.t()) => term()}

  @spec encode(term()) :: envelope()

  def encode(term), do: %{"$event_term" => 1, "value" => encode_value(term)}

  @spec decode(term(), keyword()) :: {:ok, term()} | {:error, :invalid_event_data}
  def decode(envelope, opts \\ []) do
    opts = Keyword.put_new(opts, :max_bytes, @default_max_bytes)

    with {:ok, node} <- body(envelope, opts),
         term <- read(node, {:exact, opts}, 0),
         validate = Keyword.get(opts, :validate, &Codec.valid?(&1, opts)),
         true <- validate.(term) do
      {:ok, term}
    else
      _ -> {:error, :invalid_event_data}
    end
  rescue
    _ -> {:error, :invalid_event_data}
  end

  @spec project(term(), keyword()) :: {:ok, term()} | {:error, :invalid_event_data}
  def project(envelope, opts \\ []) do
    with {:ok, node} <- body(envelope, opts), do: {:ok, read(node, :project, 0)}
  rescue
    _ -> {:error, :invalid_event_data}
  end

  defp body(%{"$event_term" => 1, "value" => node} = envelope, opts)
       when map_size(envelope) == 2 do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    if is_integer(max_bytes) and max_bytes > 0 and
         :erlang.external_size(envelope) <= max_bytes,
       do: {:ok, node},
       else: {:error, :invalid_event_data}
  end

  defp body(_, _), do: {:error, :invalid_event_data}

  defp encode_value(term) when is_number(term) or is_boolean(term) or is_nil(term), do: term

  defp encode_value(term) when is_binary(term) do
    if String.valid?(term), do: term, else: ["binary", Base.encode64(term)]
  end

  defp encode_value(term) when is_atom(term), do: ["atom", Atom.to_string(term)]

  defp encode_value(%_{} = term),
    do: ["struct", Atom.to_string(term.__struct__), pairs(Map.from_struct(term))]

  defp encode_value(term) when is_map(term), do: ["map", pairs(term)]

  defp encode_value(term) when is_tuple(term),
    do: ["tuple", Enum.map(Tuple.to_list(term), &encode_value/1)]

  defp encode_value(term) when is_list(term) do
    ["list", Enum.map(term, &encode_value/1)]
  rescue
    _ -> opaque(term)
  end

  defp encode_value(term), do: opaque(term)

  defp opaque(term),
    do: [
      "opaque",
      Base.encode64(:erlang.term_to_binary(term)),
      Alto.TermProjection.encode_term(term)
    ]

  defp pairs(map),
    do: Enum.map(map, fn {key, value} -> [encode_key(key), encode_value(value)] end)

  defp encode_key(key) when is_atom(key) or is_binary(key) or is_integer(key),
    do: encode_value(key)

  defp encode_key(key) do
    wire_key = Alto.TermProjection.encode_key(key)
    ["key", encode_value(key), wire_key]
  end

  defp read(_, _, depth) when depth > @max_depth, do: raise(ArgumentError, "event depth")

  defp read(value, _, _)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp read(["atom", name], :project, _) when is_binary(name), do: name

  defp read(["atom", name], {:exact, _}, _) when is_binary(name),
    do: String.to_existing_atom(name)

  defp read(["binary", encoded], mode, _) do
    value = Base.decode64!(encoded)
    if mode == :project, do: Alto.TermProjection.encode_term(value), else: value
  end

  defp read(["map", pairs], mode, depth), do: read_map(pairs, mode, depth)

  defp read(["struct", name, pairs], :project, depth) when is_binary(name),
    do: read_map(pairs, :project, depth)

  defp read(["struct", name, pairs], {:exact, _} = mode, depth),
    do: Map.put(read_map(pairs, mode, depth), :__struct__, String.to_existing_atom(name))

  defp read(["tuple", items], mode, depth) do
    items = Enum.map(items, &read(&1, mode, depth + 1))
    if mode == :project, do: %{"$tuple" => items}, else: List.to_tuple(items)
  end

  defp read(["list", items], mode, depth), do: Enum.map(items, &read(&1, mode, depth + 1))
  defp read(["key", node, _], {:exact, _} = mode, depth), do: read(node, mode, depth + 1)

  defp read(["opaque", encoded, projection], :project, _) when is_binary(encoded),
    do: projection

  defp read(["opaque", encoded, _], {:exact, opts}, _) do
    {:ok, term} = Codec.decode(encoded, Keyword.put_new(opts, :max_bytes, @default_max_bytes))
    term
  end

  defp read_map(pairs, mode, depth),
    do:
      Map.new(pairs, fn [key, value] ->
        {read_key(key, mode, depth + 1), read(value, mode, depth + 1)}
      end)

  defp read_key(key, {:exact, _} = mode, depth), do: read(key, mode, depth)
  defp read_key(["key", _, wire], :project, _) when is_binary(wire), do: wire

  defp read_key(["binary", encoded], :project, _),
    do: encoded |> Base.decode64!() |> Alto.TermProjection.encode_key()

  defp read_key(key, :project, depth) do
    case read(key, :project, depth) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      value when is_boolean(value) or is_nil(value) -> Atom.to_string(value)
    end
  end
end
