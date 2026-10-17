defmodule Alto.Runner.Budget.Account do
  @moduledoc """
  Durable shared effect/model counters in an `Alto.OperationLog` checkpoint.

  Reservations persist before dispatch permission; failed calls grant nothing.
  See `docs/subagents.md` for account lifetime, restoration, and accounting.
  """
  alias Alto.Persistence.Retained

  @type t :: Retained.t()
  @max 18_446_744_073_709_551_615
  @limits ["max_effects", "max_model_requests"]
  @counters ["effects_used", "model_requests_used"]

  @doc "Create or reconnect an account. Reopening can tighten but never widen caps."
  def open(ledger, key, opts) do
    with {:ok, caps} <- limits(opts),
         {:ok, account, _} <-
           Retained.open(
             ledger,
             key,
             __MODULE__,
             caps,
             Map.merge(caps, %{"effects_used" => 0, "model_requests_used" => 0}),
             Keyword.get(opts, :deadline, :infinity)
           ),
         {:ok, _} <-
           tighten(account, caps["max_effects"], caps["max_model_requests"], account.deadline) do
      {:ok, account}
    end
  end

  @doc "Portable binding used to reconnect checkpointed runs to this same account."
  def identity(account), do: Retained.identity(account)

  @doc "Look up one retained account without initializing or mutating it."
  def lookup(ledger, key, opts \\ []) do
    Retained.lookup(ledger, key, __MODULE__, opts)
  end

  @doc "Read one consistent revision, both counters, and the closure state."
  def read(account, deadline \\ :infinity)

  def read(%Retained{kind: __MODULE__} = account, deadline) do
    Retained.read(%{account | deadline: deadline})
  end

  def read(_, _), do: {:error, :invalid_budget_account}

  @doc "Lower shared caps. Already consumed counts remain consumed."
  def tighten(%Retained{kind: __MODULE__} = account, effects, models, deadline \\ :infinity) do
    if valid_cap?(effects) and valid_cap?(models) do
      Retained.update(
        %{account | deadline: deadline},
        fn %{packet: packet} ->
          {:ok,
           packet
           |> Map.update!("max_effects", &min(&1, effects))
           |> Map.update!("max_model_requests", &min(&1, models))}
        end
      )
    else
      {:error, :invalid_budget_account_limits}
    end
  end

  @doc "Reserve one unit under both the account cap and the caller's narrower cap."
  def take(%Retained{kind: __MODULE__} = account, kind, cap, deadline \\ :infinity)
      when kind in [:effect, :model] do
    if valid_cap?(cap) and (deadline == :infinity or is_integer(deadline)) do
      {counter, limit, error} =
        case kind do
          :effect -> {"effects_used", "max_effects", :effect_limit}
          :model -> {"model_requests_used", "max_model_requests", :model_request_limit}
        end

      with {:ok, _} <-
             Retained.update(
               %{account | deadline: deadline},
               fn %{packet: packet} ->
                 maximum = min(cap, packet[limit])

                 cond do
                   deadline != :infinity and System.monotonic_time(:millisecond) >= deadline ->
                     {:error, :run_timeout}

                   packet[counter] < maximum ->
                     {:ok, Map.update!(packet, counter, &(&1 + 1))}

                   true ->
                     {:error, {error, maximum}}
                 end
               end
             ),
           do: :ok
    else
      {:error, :invalid_budget_account_limits}
    end
  end

  @doc "Close an account at the viewed revision, denying future reservations. Never refunds counts."
  def close(%Retained{kind: __MODULE__} = account, expected_revision) do
    if is_integer(expected_revision) and expected_revision >= 1 do
      Retained.retire(%{account | deadline: :infinity}, expected_revision)
    else
      {:error, :invalid_budget_account_revision}
    end
  end

  @doc false
  def snapshot(%{initial: initial, packet: packet} = current)
      when is_map(initial) and is_map(packet) do
    if map_size(initial) == 2 and map_size(packet) == 4 and
         Enum.all?(@limits, &valid_cap?(initial[&1])) and
         Enum.all?(@limits, &(valid_cap?(packet[&1]) and packet[&1] <= initial[&1])) and
         Enum.all?(Enum.zip(@counters, @limits), fn {counter, cap} ->
           is_integer(packet[counter]) and packet[counter] >= 0 and
             packet[counter] <= initial[cap]
         end),
       do: {:ok, current},
       else: {:error, :invalid_budget_account}
  end

  def snapshot(_), do: {:error, :invalid_budget_account}

  defp limits(opts) do
    with true <- Keyword.keyword?(opts),
         {deadline, caps} <- Keyword.pop_first(opts, :deadline, :infinity),
         true <- deadline == :infinity or is_integer(deadline),
         [{:max_effects, effects}, {:max_model_requests, models}] <- Enum.sort(caps),
         models <- if(models == :infinity, do: @max, else: models),
         true <- valid_cap?(effects) and valid_cap?(models) do
      {:ok, %{"max_effects" => effects, "max_model_requests" => models}}
    else
      _ -> {:error, :invalid_budget_account_limits}
    end
  end

  defp valid_cap?(value), do: is_integer(value) and value >= 1 and value <= @max
end
