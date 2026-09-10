defmodule Alto.Context.Window do
  @moduledoc "A context cap resolved against the selected model's advertised window."

  defstruct [:max_tokens, reserve_output: 0, estimator: nil]

  @type t :: %__MODULE__{
          max_tokens: pos_integer() | nil,
          reserve_output: non_neg_integer(),
          estimator: (map() -> non_neg_integer()) | nil
        }

  @type budget :: %{
          context_window: pos_integer(),
          input_tokens: non_neg_integer(),
          reserve_output: non_neg_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, max_tokens: nil, reserve_output: 0, estimator: nil)
    max_tokens = Keyword.fetch!(opts, :max_tokens)
    reserve_output = Keyword.fetch!(opts, :reserve_output)

    if max_tokens != nil and (not is_integer(max_tokens) or max_tokens <= 0) do
      raise ArgumentError, "max_tokens must be a positive integer or nil"
    end

    if not is_integer(reserve_output) or reserve_output < 0 do
      raise ArgumentError, "reserve_output must be a non-negative integer"
    end

    estimator = Keyword.fetch!(opts, :estimator)

    if estimator != nil and not is_function(estimator, 1),
      do: raise(ArgumentError, "estimator must be a unary function or nil")

    %__MODULE__{max_tokens: max_tokens, reserve_output: reserve_output, estimator: estimator}
  end

  @spec resolve(t(), pos_integer()) :: budget()
  def resolve(%__MODULE__{} = policy, model_context)
      when is_integer(model_context) and model_context > 0 do
    context_window = min(policy.max_tokens || model_context, model_context)

    %{
      context_window: context_window,
      input_tokens: max(context_window - policy.reserve_output, 0),
      reserve_output: min(policy.reserve_output, context_window)
    }
  end

  @doc "Check input using a conservative byte-based token upper bound. Provider usage remains authoritative accounting."
  def check(%__MODULE__{} = policy, request, provider_info) do
    advertised =
      Map.get(provider_info, :context_window) || Map.get(provider_info, :context_length)

    advertised = if is_integer(advertised) and advertised > 0, do: advertised
    limit = advertised || policy.max_tokens

    if limit do
      budget = resolve(policy, limit)
      input = %{messages: request.messages, tools: request.tools}

      estimate =
        if policy.estimator,
          do: policy.estimator.(input),
          else: byte_size(JSON.encode!(input)) + 16 * length(request.messages) + 16

      cond do
        not is_integer(estimate) or estimate < 0 ->
          {:error, :invalid_context_estimate}

        estimate <= budget.input_tokens ->
          {:ok, budget}

        true ->
          {:error, {:context_limit, %{input_upper_bound: estimate, budget: budget.input_tokens}}}
      end
    else
      {:ok, :unavailable}
    end
  end
end
