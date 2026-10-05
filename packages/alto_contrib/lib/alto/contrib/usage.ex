defmodule Alto.Contrib.Usage do
  @moduledoc "Provider wire codecs producing canonical Alto token accounting."
  @input ~w(prompt_tokens input_tokens prompt_token_count inputTokenCount inputTokens)
  @output ~w(completion_tokens output_tokens candidates_token_count outputTokenCount outputTokens)
  @cached ~w(cache_read_input_tokens cached_input_tokens cachedContentTokenCount cachedInputTokens)
  @total ~w(total_tokens total_token_count totalTokenCount totalTokens)
  @codex_fields ~w(inputTokens outputTokens totalTokens cachedInputTokens)

  @doc "Normalize provider usage or a serialized accounting map; string keys take precedence."
  @spec normalize(term()) :: Alto.Usage.t()
  def normalize(usage) when is_map(usage) do
    usage = normalize_keys(usage)
    accounting? = Map.has_key?(usage, "requests")

    input =
      integer(usage, @input) + integer(usage, ~w(cache_read_input_tokens)) +
        integer(usage, ~w(cache_creation_input_tokens))

    output = integer(usage, @output)
    cached = min(max(integer(usage, @cached), nested_cached(usage)), input)
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

  def normalize(_), do: Alto.Usage.new()

  @doc false
  def completion({:ok, completion}),
    do: {:ok, Map.update(completion, :usage, nil, &known/1)}

  def completion({:error, %Alto.Provider.Failure{} = failure}),
    do: {:error, %{failure | usage: known(failure.usage)}}

  def completion(other), do: other

  def known(usage) when is_map(usage), do: normalize(usage)
  def known(_), do: nil

  @doc "Project a cumulative Codex thread/tokenUsage snapshot; its request count is unknown."
  @spec from_codex(term()) :: Alto.Usage.t()
  def from_codex(usage) when is_map(usage) do
    usage = normalize_keys(usage)

    case usage do
      %{"total" => total, "last" => last} when is_map(total) and is_map(last) ->
        total = total |> normalize_keys() |> Map.take(@codex_fields) |> normalize()
        last = last |> normalize_keys() |> Map.take(@codex_fields) |> normalize()

        %{
          total
          | last_input_tokens: last.input_tokens,
            last_cached_input_tokens: last.cached_input_tokens,
            context_window: integer(usage, ~w(modelContextWindow), nil),
            requests: 0
        }

      _ ->
        Alto.Usage.new()
    end
  end

  def from_codex(_), do: Alto.Usage.new()

  defp nested_cached(map) do
    Enum.find_value(~w(prompt_tokens_details input_tokens_details), 0, fn parent ->
      case map[parent] do
        nested when is_map(nested) -> integer(normalize_keys(nested), ~w(cached_tokens))
        _ -> nil
      end
    end)
  end

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
