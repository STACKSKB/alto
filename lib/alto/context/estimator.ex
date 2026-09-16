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

  @enforce_keys [:tokenizer]
  defstruct tokenizer: nil,
            provider_overhead: 0,
            message_overhead: 0,
            tool_overhead: 0,
            model: nil,
            model_overhead: %{}

  @type tokenizer :: (binary() -> non_neg_integer())
  @type t :: %__MODULE__{
          tokenizer: tokenizer(),
          provider_overhead: non_neg_integer(),
          message_overhead: non_neg_integer(),
          tool_overhead: non_neg_integer(),
          model: term(),
          model_overhead: map()
        }

  @doc "Build a unary estimator suitable for `Alto.Context.Window.new/1`."
  @spec new(keyword()) :: (map() -> non_neg_integer())
  def new(opts \\ []) when is_list(opts) do
    estimator = config(opts)
    fn input -> estimate(input, estimator) end
  end

  @doc "Estimate a request using an estimator config or a unary tokenizer config."
  @spec estimate(map(), t() | keyword()) :: non_neg_integer()
  def estimate(input, %__MODULE__{} = config) when is_map(input) do
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

  def estimate(input, opts) when is_map(input) and is_list(opts),
    do: estimate(input, config(opts))

  def estimate(_input, _config), do: raise(ArgumentError, "context input must be a map")

  @doc "Build the config struct when callers need to inspect or reuse it."
  @spec config(keyword()) :: t()
  def config(opts \\ []) when is_list(opts) do
    opts =
      Keyword.validate!(opts,
        tokenizer: &default_tokenizer/1,
        provider_overhead: 0,
        message_overhead: 0,
        tool_overhead: 0,
        model: nil,
        model_overhead: %{}
      )

    tokenizer = Keyword.fetch!(opts, :tokenizer)
    provider_overhead = Keyword.fetch!(opts, :provider_overhead)
    message_overhead = Keyword.fetch!(opts, :message_overhead)
    tool_overhead = Keyword.fetch!(opts, :tool_overhead)
    model_overhead = Keyword.fetch!(opts, :model_overhead)

    cond do
      not is_function(tokenizer, 1) ->
        raise ArgumentError, "tokenizer must be a unary function"

      not non_negative_integer?(provider_overhead) ->
        raise ArgumentError, "provider_overhead must be a non-negative integer"

      not non_negative_integer?(message_overhead) ->
        raise ArgumentError, "message_overhead must be a non-negative integer"

      not non_negative_integer?(tool_overhead) ->
        raise ArgumentError, "tool_overhead must be a non-negative integer"

      not is_map(model_overhead) ->
        raise ArgumentError, "model_overhead must be a map"

      not Enum.all?(model_overhead, fn {_model, overhead} -> non_negative_integer?(overhead) end) ->
        raise ArgumentError, "model_overhead values must be non-negative integers"

      true ->
        %__MODULE__{
          tokenizer: tokenizer,
          provider_overhead: provider_overhead,
          message_overhead: message_overhead,
          tool_overhead: tool_overhead,
          model: Keyword.fetch!(opts, :model),
          model_overhead: model_overhead
        }
    end
  end

  defp tokenize_entry(acc, entry, tokenizer, overhead) do
    tokens = tokenizer.(JSON.encode!(entry))

    if non_negative_integer?(tokens),
      do: acc + tokens + overhead,
      else: raise(ArgumentError, "tokenizer must return a non-negative integer")
  end

  # This conservative fallback keeps Window useful without an external
  # tokenizer. A byte count is an upper bound only for the configured policy,
  # not a claim about a provider's actual tokenization.
  defp default_tokenizer(text), do: byte_size(text)

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
