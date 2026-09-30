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

      case Retained.update(
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
           ) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
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
  def snapshot(%{initial: initial, packet: packet} = current) do
    with :ok <- valid_initial(initial), :ok <- valid_packet(packet, initial), do: {:ok, current}
  end

  defp valid_initial(initial) when is_map(initial) do
    if Enum.sort(Map.keys(initial)) == Enum.sort(@limits) and
         Enum.all?(@limits, &valid_cap?(initial[&1])),
       do: :ok,
       else: {:error, :invalid_budget_account}
  end

  defp valid_initial(_), do: {:error, :invalid_budget_account}

  defp valid_packet(packet, initial) when is_map(packet) do
    if map_size(packet) == 4 and
         Enum.all?(@limits, &(valid_cap?(packet[&1]) and packet[&1] <= initial[&1])) and
         Enum.all?(Enum.zip(@counters, @limits), fn {counter, cap} ->
           is_integer(packet[counter]) and packet[counter] >= 0 and
             packet[counter] <= initial[cap]
         end),
       do: :ok,
       else: {:error, :invalid_budget_account}
  end

  defp valid_packet(_, _), do: {:error, :invalid_budget_account}

  defp limits(opts) do
    opts =
      if Keyword.keyword?(opts),
        do:
          Keyword.update(opts, :max_model_requests, nil, fn
            :infinity -> @max
            limit -> limit
          end),
        else: opts

    keys = if Keyword.keyword?(opts), do: Keyword.keys(opts), else: []

    if Keyword.keyword?(opts) and
         Enum.sort(keys -- [:deadline]) == [:max_effects, :max_model_requests] and
         (not Keyword.has_key?(opts, :deadline) or
            Keyword.get(opts, :deadline) == :infinity or is_integer(Keyword.get(opts, :deadline))) and
         Enum.all?(Keyword.take(opts, [:max_effects, :max_model_requests]), fn {_, value} ->
           valid_cap?(value)
         end),
       do:
         {:ok,
          opts
          |> Keyword.take([:max_effects, :max_model_requests])
          |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)},
       else: {:error, :invalid_budget_account_limits}
  end

  defp valid_cap?(value), do: is_integer(value) and value >= 1 and value <= @max
end
