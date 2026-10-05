defmodule Alto.Usage do
  @moduledoc """
  Provider-neutral token accounting as an atom-keyed map.

  Adapters decode their wire fields before ingestion. Accounting maps flow unchanged
  through execution, events, results and front ends. Totals sum observed usage;
  `requests` counts reports rather than transport attempts. Unknown attempt usage
  remains `nil` in `Result.provider_attempts`, so zero totals never prove zero
  consumption. Cache reads remain separate
  from total input and the most recent request remains separate from totals.
  """

  @cumulative ~w(input_tokens output_tokens total_tokens cached_input_tokens requests)a
  @empty Map.new(@cumulative ++ [:last_input_tokens, :last_cached_input_tokens], &{&1, 0})
         |> Map.put(:context_window, nil)
  @input ~w(input_tokens)
  @output ~w(output_tokens)
  @cached ~w(cached_input_tokens)
  @total ~w(total_tokens)

  @type t :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          last_input_tokens: non_neg_integer(),
          last_cached_input_tokens: non_neg_integer(),
          context_window: non_neg_integer() | nil,
          requests: non_neg_integer()
        }

  @doc "Return zeroed accounting."
  @spec new() :: t()
  def new, do: @empty

  def valid?(usage) when is_map(usage) do
    Enum.sort(Map.keys(usage)) == Enum.sort(Map.keys(@empty)) and
      Enum.all?(usage, fn
        {:context_window, nil} -> true
        {_, value} -> is_integer(value) and value >= 0
      end)
  end

  def valid?(_), do: false

  @doc "Normalize canonical request usage or a serialized accounting map; string keys take precedence."
  @spec normalize(term()) :: t()
  def normalize(usage) when is_map(usage) do
    usage = normalize_keys(usage)
    accounting? = Map.has_key?(usage, "requests")

    input = integer(usage, @input)

    output = integer(usage, @output)
    cached = min(integer(usage, @cached), input)
    last_input = integer(usage, ~w(last_input_tokens), input)

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: integer(usage, @total, if(accounting?, do: 0, else: input + output)),
      cached_input_tokens: cached,
      last_input_tokens: last_input,
      last_cached_input_tokens:
        min(
          integer(usage, ~w(last_cached_input_tokens), if(accounting?, do: 0, else: cached)),
          last_input
        ),
      context_window: integer(usage, ~w(context_window), nil),
      requests: if(accounting?, do: integer(usage, ~w(requests)), else: 1)
    }
  end

  def normalize(_), do: new()

  @doc "Sum cumulative fields; a new request replaces the latest-request fields."
  @spec merge(t(), t()) :: t()
  def merge(left, right) do
    latest = if right.requests > 0, do: right, else: left
    Map.merge(latest, Map.new(@cumulative, &{&1, Map.fetch!(left, &1) + Map.fetch!(right, &1)}))
  end

  @doc "Percentage of input tokens served from provider cache."
  def cache_hit_rate(usage), do: rate(usage.cached_input_tokens, usage.input_tokens)

  @doc "Cache-hit percentage of the most recent model request."
  def last_cache_hit_rate(usage),
    do: min(rate(usage.last_cached_input_tokens, usage.last_input_tokens), 100.0)

  defp rate(_, 0), do: 0.0
  defp rate(cached, input), do: cached / input * 100.0

  defp integer(map, keys, default \\ 0) do
    Enum.find_value(keys, default, fn key ->
      case map[key] do
        n when is_integer(n) and n >= 0 -> n
        _ -> nil
      end
    end)
  end

  defp normalize_keys(map) do
    strings = for {key, value} when is_binary(key) <- map, into: %{}, do: {key, value}
    atoms = for {key, value} when is_atom(key) <- map, into: %{}, do: {Atom.to_string(key), value}
    Map.merge(atoms, strings)
  end
end
