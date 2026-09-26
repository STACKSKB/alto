defmodule Alto.Context.Estimator do
  @moduledoc """
  Adapt a text tokenizer to Alto's unary context estimator contract.

  `Alto.Context.Window` calls its estimator with `%{messages: ..., tools: ...}`.
  This adapter tokenizes each serialized message and tool definition, then adds
  configured provider and model framing overhead. The result is an estimate for
  admission control; provider usage remains authoritative after dispatch.

  Token counts are only as useful as the tokenizer and framing values supplied
  by the caller. They are not exact model counts unless those values have been
  calibrated for the selected provider, model, and request shape.
  """

  @doc "Build a unary estimator suitable for `Alto.Context.Window.new/1`."
  @spec new(keyword()) :: (map() -> non_neg_integer())
  def new(opts \\ []) when is_list(opts) do
    config =
      opts
      |> NimbleOptions.validate!(
        tokenizer: [type: {:fun, 1}, default: &:erlang.byte_size/1],
        provider_overhead: [type: :non_neg_integer, default: 0],
        message_overhead: [type: :non_neg_integer, default: 0],
        tool_overhead: [type: :non_neg_integer, default: 0],
        model: [type: :any, default: nil],
        model_overhead: [type: {:map, :any, :non_neg_integer}, default: %{}]
      )
      |> Map.new()

    fn input -> estimate(input, config) end
  end

  defp estimate(input, config) when is_map(input) do
    messages = Map.get(input, :messages, Map.get(input, "messages", []))
    tools = Map.get(input, :tools, Map.get(input, "tools", []))

    if is_list(messages) and is_list(tools) do
      model_overhead = Map.get(config.model_overhead, config.model, 0)

      config.provider_overhead + model_overhead +
        Enum.reduce(
          messages,
          0,
          &tokenize_entry(&2, &1, config.tokenizer, config.message_overhead)
        ) +
        Enum.reduce(tools, 0, &tokenize_entry(&2, &1, config.tokenizer, config.tool_overhead))
    else
      raise ArgumentError, "context input must contain message and tool lists"
    end
  end

  defp estimate(_input, _config), do: raise(ArgumentError, "context input must be a map")

  defp tokenize_entry(acc, entry, tokenizer, overhead) do
    tokens = tokenizer.(JSON.encode!(entry))

    if is_integer(tokens) and tokens >= 0,
      do: acc + tokens + overhead,
      else: raise(ArgumentError, "tokenizer must return a non-negative integer")
  end
end
