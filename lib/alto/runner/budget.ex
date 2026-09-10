defmodule Alto.Runner.Budget do
  @moduledoc "A shared effect budget and monotonic deadline for a run and its descendants."
  alias Alto.Runner.Budget.Account
  defstruct [:counter, :account, :max_effects, :max_model_requests, :deadline]

  @default_max_effects 10_000
  @default_max_model_requests 256
  @default_run_timeout 900_000
  @max_uint64 18_446_744_073_709_551_615

  @type t :: %__MODULE__{
          counter: :atomics.atomics_ref() | nil,
          account: Account.t() | nil,
          max_effects: pos_integer(),
          max_model_requests: pos_integer(),
          deadline: integer()
        }

  def new(opts) do
    max_effects = Keyword.get(opts, :max_effects, @default_max_effects)
    models = Keyword.get(opts, :max_model_requests, @default_max_model_requests)
    timeout = Keyword.get(opts, :run_timeout, @default_run_timeout)

    cond do
      not valid_cap?(models) ->
        {:error, {:invalid_option, :max_model_requests, models}}

      not valid_cap?(max_effects) ->
        {:error, {:invalid_option, :max_effects, max_effects}}

      not is_integer(timeout) or timeout < 1 ->
        {:error, {:invalid_option, :run_timeout, timeout}}

      true ->
        attach_account(
          %__MODULE__{
            counter: :atomics.new(2, signed: false),
            max_effects: max_effects,
            max_model_requests: models,
            deadline: System.monotonic_time(:millisecond) + timeout
          },
          Keyword.get(opts, :budget_account)
        )
    end
  end

  defp attach_account(budget, nil), do: {:ok, budget}

  defp attach_account(budget, %Account{} = account) do
    with {:ok, %{packet: packet}} <-
           Account.tighten(account, budget.max_effects, budget.max_model_requests) do
      {:ok,
       %{
         budget
         | counter: nil,
           account: account,
           max_effects: packet["max_effects"],
           max_model_requests: packet["max_model_requests"]
       }}
    end
  end

  defp attach_account(_, other), do: {:error, {:invalid_option, :budget_account, other}}

  @doc "Return a portable, string-key snapshot of counters, caps, and remaining time."
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{account: %Account{} = account} = budget) do
    case Account.read(account) do
      {:ok, %{packet: packet}} ->
        packet
        |> Map.take(["effects_used", "model_requests_used"])
        |> Map.merge(%{
          "max_effects" => min(budget.max_effects, packet["max_effects"]),
          "max_model_requests" => min(budget.max_model_requests, packet["max_model_requests"]),
          "remaining_ms" => remaining(budget),
          "account" => Account.identity(account)
        })

      {:error, reason} ->
        raise "cannot snapshot budget account: #{inspect(reason)}"
    end
  end

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
         :ok <- validate_binding(opts, snapshot),
         {:ok, current} <- new(opts),
         :ok <- check_account_floor(current, snapshot) do
      max_effects = min(current.max_effects, snapshot["max_effects"])
      max_models = min(current.max_model_requests, snapshot["max_model_requests"])
      remaining_ms = min(current |> remaining(), snapshot["remaining_ms"])

      restored = %{
        current
        | max_effects: max_effects,
          max_model_requests: max_models,
          deadline: System.monotonic_time(:millisecond) + remaining_ms
      }

      restore_counters(restored, snapshot)
    end
  end

  def restore(_opts, _snapshot), do: {:error, :invalid_snapshot}

  defp restore_counters(%{account: nil} = budget, snapshot) do
    :atomics.put(budget.counter, 1, snapshot["effects_used"])
    :atomics.put(budget.counter, 2, snapshot["model_requests_used"])
    {:ok, budget}
  end

  defp restore_counters(budget, _snapshot), do: attach_account(budget, budget.account)

  defp validate_binding(opts, snapshot) do
    case {Keyword.get(opts, :budget_account), Map.get(snapshot, "account")} do
      {nil, nil} ->
        :ok

      {%Account{} = account, identity} when is_map(identity) ->
        if Account.identity(account) == identity,
          do: :ok,
          else: {:error, :budget_account_mismatch}

      _ ->
        {:error, :budget_account_mismatch}
    end
  end

  defp check_account_floor(%{account: nil}, _snapshot), do: :ok

  defp check_account_floor(%{account: account}, snapshot) do
    with {:ok, %{packet: packet}} <- Account.read(account) do
      if packet["effects_used"] >= snapshot["effects_used"] and
           packet["model_requests_used"] >= snapshot["model_requests_used"],
         do: :ok,
         else: {:error, :budget_account_rollback}
    end
  end

  defp validate_snapshot(snapshot) do
    required = [
      "effects_used",
      "model_requests_used",
      "max_effects",
      "max_model_requests",
      "remaining_ms"
    ]

    expected = if Map.has_key?(snapshot, "account"), do: ["account" | required], else: required

    if Enum.sort(Map.keys(snapshot)) != Enum.sort(expected) or
         not valid_account_identity?(Map.get(snapshot, "account")) do
      {:error, :invalid_snapshot}
    else
      fields = Enum.map(required, &Map.fetch!(snapshot, &1))

      case fields do
        [effects, models, max_effects, max_models, remaining]
        when is_integer(effects) and effects >= 0 and effects <= @max_uint64 and
               is_integer(models) and models >= 0 and models <= @max_uint64 and
               is_integer(max_effects) and max_effects >= 1 and max_effects <= @max_uint64 and
               is_integer(max_models) and max_models >= 1 and max_models <= @max_uint64 and
               is_integer(remaining) and remaining >= 0 ->
          :ok

        _ ->
          {:error, :invalid_snapshot}
      end
    end
  end

  defp valid_account_identity?(nil), do: true

  defp valid_account_identity?(%{"key" => key, "generation" => generation} = identity) do
    map_size(identity) == 2 and is_binary(key) and byte_size(key) in 1..256 and
      is_binary(generation) and byte_size(generation) == 32
  end

  defp valid_account_identity?(_), do: false

  def check(%__MODULE__{} = budget) do
    if remaining(budget) > 0, do: :ok, else: {:error, :run_timeout}
  end

  def take(%__MODULE__{} = budget) do
    reserve(budget, 1, budget.max_effects, {:effect_limit, budget.max_effects})
  end

  def take_model(%__MODULE__{} = budget) do
    reserve(
      budget,
      2,
      budget.max_model_requests,
      {:model_request_limit, budget.max_model_requests}
    )
  end

  defp reserve(%__MODULE__{account: %Account{} = account} = budget, index, cap, _error) do
    with :ok <- check(budget),
         :ok <-
           Account.take(account, if(index == 1, do: :effect, else: :model), cap, budget.deadline),
         do: check(budget)
  end

  defp reserve(%__MODULE__{} = budget, index, cap, limit_error) do
    with :ok <- check(budget) do
      current = :atomics.get(budget.counter, index)

      cond do
        current >= cap ->
          {:error, limit_error}

        :atomics.compare_exchange(budget.counter, index, current, current + 1) == :ok ->
          :ok

        true ->
          # A competing reservation won the CAS. Recheck the deadline before
          # retrying so an expired budget never reserves another slot.
          reserve(budget, index, cap, limit_error)
      end
    end
  end

  defp valid_cap?(value), do: is_integer(value) and value >= 1 and value <= @max_uint64

  def remaining(%__MODULE__{deadline: deadline}),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  def timeout(budget, local), do: min(remaining(budget), local)
end
