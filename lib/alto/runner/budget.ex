defmodule Alto.Runner.Budget do
  @moduledoc "A shared effect budget and monotonic deadline for a run and its descendants."
  defstruct [:counter, :max_effects, :max_model_requests, :deadline]

  def new(opts) do
    max_effects = Keyword.get(opts, :max_effects, 10_000)
    models = Keyword.get(opts, :max_model_requests, 256)
    timeout = Keyword.get(opts, :run_timeout, 900_000)

    cond do
      not is_integer(models) or models < 1 ->
        {:error, {:invalid_option, :max_model_requests, models}}

      not is_integer(max_effects) or max_effects < 1 ->
        {:error, {:invalid_option, :max_effects, max_effects}}

      not is_integer(timeout) or timeout < 1 ->
        {:error, {:invalid_option, :run_timeout, timeout}}

      true ->
        {:ok,
         %__MODULE__{
           counter: :atomics.new(2, signed: false),
           max_effects: max_effects,
           max_model_requests: models,
           deadline: System.monotonic_time(:millisecond) + timeout
         }}
    end
  end

  def check(%__MODULE__{} = budget) do
    if remaining(budget) > 0, do: :ok, else: {:error, :run_timeout}
  end

  def take(%__MODULE__{} = budget) do
    with :ok <- check(budget) do
      if :atomics.add_get(budget.counter, 1, 1) <= budget.max_effects,
        do: :ok,
        else: {:error, {:effect_limit, budget.max_effects}}
    end
  end

  def take_model(%__MODULE__{} = budget) do
    with :ok <- check(budget) do
      if :atomics.add_get(budget.counter, 2, 1) <= budget.max_model_requests,
        do: :ok,
        else: {:error, {:model_request_limit, budget.max_model_requests}}
    end
  end

  def remaining(%__MODULE__{deadline: deadline}),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  def timeout(budget, local), do: min(remaining(budget), local)
end
