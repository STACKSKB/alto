defmodule Alto.Usage do
  @moduledoc """
  Provider-neutral token accounting for run results and front ends.

  Providers may return their native usage map. Alto recognizes the common
  OpenAI, Anthropic, and Google field names, keeps unknown shapes harmless,
  and reports cache reads separately so a front end can calculate a real
  cache-hit rate instead of estimating one from transcript bytes.
  """

  @enforce_keys [
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :cached_input_tokens,
    :last_input_tokens,
    :requests
  ]
  defstruct input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            cached_input_tokens: 0,
            last_input_tokens: 0,
            requests: 0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          last_input_tokens: non_neg_integer(),
          requests: non_neg_integer()
        }

  @doc "Return zeroed accounting."
  @spec new() :: t()
  def new do
    %__MODULE__{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cached_input_tokens: 0,
      last_input_tokens: 0,
      requests: 0
    }
  end

  @doc "Normalize one provider response usage object."
  @spec normalize(map() | nil | term()) :: t()
  def normalize(usage) when is_map(usage) do
    base_input =
      integer(usage, ~w(prompt_tokens input_tokens prompt_token_count inputTokenCount))

    output =
      integer(usage, ~w(completion_tokens output_tokens candidates_token_count outputTokenCount))

    cache_read = integer(usage, ~w(cache_read_input_tokens))
    cache_creation = integer(usage, ~w(cache_creation_input_tokens))

    input =
      if present?(usage, ~w(cache_read_input_tokens cache_creation_input_tokens)) do
        base_input + cache_read + cache_creation
      else
        base_input
      end

    cached =
      max(
        integer(usage, ~w(cache_read_input_tokens cached_input_tokens cachedContentTokenCount)),
        nested_integer(usage, ~w(prompt_tokens_details input_tokens_details), ~w(cached_tokens))
      )

    total = integer(usage, ~w(total_tokens total_token_count totalTokenCount))
    total = if total == 0, do: input + output, else: total

    %__MODULE__{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      cached_input_tokens: min(cached, input),
      last_input_tokens: input,
      requests: 1
    }
  end

  def normalize(_usage), do: new()

  @doc "Add token accounting across requests."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = left, %__MODULE__{} = right) do
    %__MODULE__{
      input_tokens: left.input_tokens + right.input_tokens,
      output_tokens: left.output_tokens + right.output_tokens,
      total_tokens: left.total_tokens + right.total_tokens,
      cached_input_tokens: left.cached_input_tokens + right.cached_input_tokens,
      last_input_tokens:
        if(right.requests > 0, do: right.last_input_tokens, else: left.last_input_tokens),
      requests: left.requests + right.requests
    }
  end

  @doc "Convert accounting to a JSON- and protocol-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = usage), do: Map.from_struct(usage)

  @doc "Percentage of input tokens served from provider cache."
  @spec cache_hit_rate(t() | map()) :: float()
  def cache_hit_rate(%__MODULE__{input_tokens: 0}), do: 0.0

  def cache_hit_rate(%__MODULE__{} = usage) do
    usage.cached_input_tokens / usage.input_tokens * 100.0
  end

  def cache_hit_rate(usage) when is_map(usage) do
    usage
    |> from_map()
    |> cache_hit_rate()
  end

  @doc "Rehydrate normalized accounting received through an event or session."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      input_tokens: integer(map, ~w(input_tokens)),
      output_tokens: integer(map, ~w(output_tokens)),
      total_tokens: integer(map, ~w(total_tokens)),
      cached_input_tokens: integer(map, ~w(cached_input_tokens)),
      last_input_tokens:
        integer(map, ~w(last_input_tokens)) |> default_last_input(integer(map, ~w(input_tokens))),
      requests: integer(map, ~w(requests))
    }
  end

  @doc "Project an authoritative Codex App Server thread/tokenUsage snapshot."
  @spec from_codex(map()) :: t()
  def from_codex(%{"total" => total, "last" => last}) when is_map(total) and is_map(last) do
    input = integer(total, ~w(inputTokens))
    output = integer(total, ~w(outputTokens))

    %__MODULE__{
      input_tokens: input,
      output_tokens: output,
      total_tokens: integer(total, ~w(totalTokens)) |> default_total(input + output),
      cached_input_tokens: min(integer(total, ~w(cachedInputTokens)), input),
      last_input_tokens: integer(last, ~w(inputTokens)),
      requests: 1
    }
  end

  def from_codex(_usage), do: new()

  defp nested_integer(map, parents, children) do
    Enum.find_value(parents, 0, fn parent ->
      case value(map, parent) do
        nested when is_map(nested) -> integer(nested, children)
        _other -> nil
      end
    end)
  end

  defp integer(map, keys) do
    Enum.find_value(keys, 0, fn key ->
      case value(map, key) do
        n when is_integer(n) and n >= 0 -> n
        _other -> nil
      end
    end)
  end

  defp present?(map, keys), do: Enum.any?(keys, &(not is_nil(value(map, &1))))

  defp value(map, key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom, value} when is_atom(atom) -> if Atom.to_string(atom) == key, do: value
        _other -> nil
      end)
  end

  defp default_last_input(0, input), do: input
  defp default_last_input(value, _input), do: value

  defp default_total(0, computed), do: computed
  defp default_total(value, _computed), do: value
end
