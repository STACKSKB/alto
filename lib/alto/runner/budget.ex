defmodule Alto.Runner.Budget do
  @moduledoc "A shared effect budget and monotonic deadline for a run and its descendants."
  defstruct [:counter, :max_effects, :max_model_requests, :deadline]

  @default_max_effects 10_000
  @default_max_model_requests 256
  @default_run_timeout 900_000
  @max_uint64 18_446_744_073_709_551_615

  @type t :: %__MODULE__{
          counter: :atomics.atomics_ref(),
          max_effects: pos_integer(),
          max_model_requests: pos_integer(),
          deadline: integer()
        }

  def new(opts) do
    max_effects = Keyword.get(opts, :max_effects, @default_max_effects)
    models = Keyword.get(opts, :max_model_requests, @default_max_model_requests)
    timeout = Keyword.get(opts, :run_timeout, @default_run_timeout)

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

  @doc "Return a portable, string-key snapshot of counters, caps, and remaining time."
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = budget) do
    %{
      "effects_used" => :atomics.get(budget.counter, 1),
      "model_requests_used" => :atomics.get(budget.counter, 2),
      "max_effects" => budget.max_effects,
      "max_model_requests" => budget.max_model_requests,
      "remaining_ms" => remaining(budget)
    }
  end

  @doc "Restore a budget without widening saved caps or remaining execution time."
  @spec restore(keyword(), map()) :: {:ok, t()} | {:error, term()}
  def restore(opts, snapshot) when is_list(opts) and is_map(snapshot) do
    with :ok <- validate_snapshot(snapshot),
         {:ok, current} <- new(opts) do
      max_effects = min(current.max_effects, snapshot["max_effects"])
      max_models = min(current.max_model_requests, snapshot["max_model_requests"])
      remaining_ms = min(current |> remaining(), snapshot["remaining_ms"])
      counter = :atomics.new(2, signed: false)
      :atomics.put(counter, 1, snapshot["effects_used"])
      :atomics.put(counter, 2, snapshot["model_requests_used"])

      {:ok,
       %__MODULE__{
         counter: counter,
         max_effects: max_effects,
         max_model_requests: max_models,
         deadline: System.monotonic_time(:millisecond) + remaining_ms
       }}
    end
  end

  def restore(_opts, _snapshot), do: {:error, :invalid_snapshot}

  defp validate_snapshot(snapshot) do
    required = [
      "effects_used",
      "model_requests_used",
      "max_effects",
      "max_model_requests",
      "remaining_ms"
    ]

    if Map.keys(snapshot) |> Enum.sort() != Enum.sort(required) do
      {:error, :invalid_snapshot}
    else
      fields = Enum.map(required, &Map.fetch!(snapshot, &1))

      case fields do
        [effects, models, max_effects, max_models, remaining]
        when is_integer(effects) and effects >= 0 and effects <= @max_uint64 and
               is_integer(models) and models >= 0 and models <= @max_uint64 and
               is_integer(max_effects) and max_effects >= 1 and
               is_integer(max_models) and max_models >= 1 and
               is_integer(remaining) and remaining >= 0 ->
          :ok

        _ ->
          {:error, :invalid_snapshot}
      end
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
