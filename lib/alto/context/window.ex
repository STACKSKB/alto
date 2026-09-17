defmodule Alto.Context.Window do
  @moduledoc "A context cap resolved against the selected model's advertised window."

  @behaviour Alto.Context.Policy

  defstruct [
    :max_tokens,
    reserve_output: 0,
    estimator: nil,
    compact_at: nil,
    usage_estimation: false
  ]

  @type t :: %__MODULE__{
          max_tokens: pos_integer() | nil,
          reserve_output: non_neg_integer(),
          compact_at: float() | nil,
          usage_estimation: boolean(),
          estimator: (map() -> non_neg_integer()) | nil
        }

  @type budget :: %{
          context_window: pos_integer(),
          input_tokens: non_neg_integer(),
          reserve_output: non_neg_integer()
        }

  @options_schema [
    max_tokens: [type: {:or, [:pos_integer, nil]}, default: nil],
    reserve_output: [type: :non_neg_integer, default: 0],
    estimator: [type: {:or, [{:fun, 1}, nil]}, default: nil],
    compact_at: [type: {:or, [:float, :integer, nil]}, default: nil],
    usage_estimation: [type: :boolean, default: false]
  ]

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = NimbleOptions.validate!(opts, @options_schema)
    fraction = opts[:compact_at]

    if fraction != nil and (fraction <= 0 or fraction > 1),
      do: raise(ArgumentError, "compact_at must be a fraction greater than zero and at most one")

    struct!(__MODULE__, opts)
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

  # An unchanged observed prefix already has an authoritative provider count.
  # Charge every new suffix byte as a token, retaining a conservative margin.
  # A compaction or tool change invalidates the observation automatically.
  defp observed_estimate(%{usage_estimation: true}, %{context_observation: observation} = request)
       when is_map(observation) do
    previous = observation.messages
    {prefix, suffix} = Enum.split(request.messages, length(previous))

    if observation.input_tokens > 0 and prefix == previous and request.tools == observation.tools do
      observation.input_tokens +
        Enum.reduce(suffix, 0, &(byte_size(JSON.encode!(&1)) + 16 + &2))
    end
  end

  defp observed_estimate(_, _), do: nil

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
          else:
            observed_estimate(policy, request) ||
              byte_size(JSON.encode!(input)) + 16 * length(request.messages) + 16

      cond do
        not is_integer(estimate) or estimate < 0 ->
          {:error, :invalid_context_estimate}

        estimate <= budget.input_tokens ->
          if policy.compact_at && estimate > budget.input_tokens * policy.compact_at,
            do: {:ok, Map.put(budget, :pressure, true)},
            else: {:ok, budget}

        true ->
          {:error, {:context_limit, %{input_upper_bound: estimate, budget: budget.input_tokens}}}
      end
    else
      {:ok, :unavailable}
    end
  end
end
