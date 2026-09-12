defmodule Alto.Runner.Budget.Account do
  @moduledoc """
  Durable shared effect/model counters in an `Alto.OperationLog` checkpoint.

  Reservations are persisted before returning permission to dispatch. A failed
  or uncertain call never grants permission, and consumed reservations are not
  refunded. This is an admission budget, not a billing or execution ledger.
  Counters persist independently of runner snapshots. The caller owns the
  ledger lifetime and chooses a unique key for each execution tree.
  """
  alias Alto.Persistence.Retained

  @enforce_keys [:ledger, :key, :generation]
  defstruct [:ledger, :key, :generation]
  @type t :: %__MODULE__{ledger: GenServer.server(), key: binary(), generation: binary()}
  @max 18_446_744_073_709_551_615
  @kind "alto_budget_account"
  @attempt "initialize-budget"
  @close "close-budget"
  @limits ["max_effects", "max_model_requests"]
  @counters ["effects_used", "model_requests_used"]

  @doc "Create or reconnect an account. Reopening can tighten but never widen caps."
  def open(ledger, key, opts) do
    with {:ok, caps} <- limits(opts) do
      initial =
        Map.merge(caps, %{
          "kind" => @kind,
          "version" => 1,
          "generation" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        })

      deadline = Keyword.get(opts, :deadline, :infinity)

      safe(fn ->
        with :ok <- Retained.deadline_ok(deadline),
             {:ok, entry} <- Retained.ensure_intent(ledger, key, @kind, nil, initial, deadline),
             :ok <- valid_initial(entry),
             account = %__MODULE__{
               ledger: ledger,
               key: key,
               generation: entry.recovery["generation"]
             },
             :ok <- initialize(account, entry, deadline),
             {:ok, _} <-
               tighten(account, caps["max_effects"], caps["max_model_requests"], deadline) do
          {:ok, account}
        end
      end)
    end
  end

  @doc "Portable binding used to reconnect checkpointed runs to this same account."
  def identity(%__MODULE__{key: key, generation: generation}),
    do: %{"key" => key, "generation" => generation}

  @doc "Look up one retained account without initializing or mutating it."
  def lookup(ledger, key, opts \\ []) do
    with {:ok, deadline} <- deadline_option(opts) do
      safe(fn ->
        with {:ok, entry} <- Retained.read(ledger, key, deadline),
             :ok <- valid_initial(entry),
             :ok <- valid_packet(entry.checkpoint, entry.recovery),
             {:ok, state} <- lifecycle(entry) do
          account = %__MODULE__{
            ledger: ledger,
            key: key,
            generation: entry.recovery["generation"]
          }

          {:ok, account, %{revision: entry.revision, packet: entry.checkpoint, state: state}}
        else
          false -> {:error, :budget_account_mismatch}
          {:error, _} = error -> error
        end
      end)
    end
  end

  @doc "Read one consistent revision, both counters, and the closure state."
  def read(%__MODULE__{} = account), do: read(account, :infinity)

  def read(%__MODULE__{} = account, deadline) do
    safe(fn ->
      with {:ok, entry} <- Retained.read(account.ledger, account.key, deadline),
           :ok <- valid_initial(entry),
           true <- entry.recovery["generation"] == account.generation,
           :ok <- valid_packet(entry.checkpoint, entry.recovery),
           {:ok, state} <- lifecycle(entry) do
        {:ok, %{revision: entry.revision, packet: entry.checkpoint, state: state}}
      else
        false -> {:error, :budget_account_mismatch}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Lower shared caps. Already consumed counts remain consumed."
  def tighten(%__MODULE__{} = account, effects, models) do
    tighten(account, effects, models, :infinity)
  end

  def tighten(%__MODULE__{} = account, effects, models, deadline) do
    if valid_cap?(effects) and valid_cap?(models) do
      update(
        account,
        fn packet ->
          {:ok,
           packet
           |> Map.update!("max_effects", &min(&1, effects))
           |> Map.update!("max_model_requests", &min(&1, models))}
        end,
        deadline
      )
    else
      {:error, :invalid_budget_account_limits}
    end
  end

  @doc "Reserve one unit under both the account cap and the caller's narrower cap."
  def take(%__MODULE__{} = account, kind, cap, deadline \\ :infinity)
      when kind in [:effect, :model] do
    if valid_cap?(cap) and (deadline == :infinity or is_integer(deadline)) do
      {counter, limit, error} =
        case kind do
          :effect -> {"effects_used", "max_effects", :effect_limit}
          :model -> {"model_requests_used", "max_model_requests", :model_request_limit}
        end

      case update(
             account,
             fn packet ->
               maximum = min(cap, packet[limit])

               cond do
                 deadline != :infinity and System.monotonic_time(:millisecond) >= deadline ->
                   {:error, :run_timeout}

                 packet[counter] < maximum ->
                   {:ok, Map.update!(packet, counter, &(&1 + 1))}

                 true ->
                   {:error, {error, maximum}}
               end
             end,
             deadline
           ) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_budget_account_limits}
    end
  end

  @doc "Close an account at the viewed revision, denying future reservations. Never refunds counts."
  def close(%__MODULE__{} = account, expected_revision) do
    if is_integer(expected_revision) and expected_revision >= 1 do
      safe(fn ->
        with {:ok, snapshot} <- read(account),
             true <- snapshot.revision == expected_revision,
             :ok <- begin_close(account, snapshot),
             :ok <- finish_close(account) do
          :ok
        else
          false -> {:error, :stale_revision}
          {:error, _} = error -> error
        end
      end)
    else
      {:error, :invalid_budget_account_revision}
    end
  end

  defp begin_close(account, %{state: :active, revision: revision}) do
    with {:ok, _} <-
           Retained.resume(
             account.ledger,
             account.key,
             revision,
             %{"action" => "close_budget", "generation" => account.generation},
             :infinity
           ),
         do: :ok
  end

  defp begin_close(_, %{state: state}) when state in [:closing, :closed], do: :ok

  defp finish_close(account) do
    with {:ok, snapshot} <- read(account) do
      if snapshot.state == :closed do
        :ok
      else
        evidence = Map.take(snapshot.packet, @limits ++ @counters)

        case Retained.record_attempt(account.ledger, account.key, @close, :infinity) do
          :ok ->
            case Retained.record_outcome(
                   account.ledger,
                   account.key,
                   @close,
                   :completed,
                   evidence,
                   :infinity
                 ) do
              :ok -> :ok
              {:error, :already_decided} -> closed_after_race(account)
              error -> error
            end

          {:error, :already_decided} ->
            closed_after_race(account)

          error ->
            error
        end
      end
    end
  end

  defp closed_after_race(account) do
    case read(account) do
      {:ok, %{state: :closed}} -> :ok
      {:ok, _} -> {:error, :budget_account_not_closed}
      error -> error
    end
  end

  defp update(account, fun, deadline) do
    safe(fn ->
      with :ok <- Retained.deadline_ok(deadline),
           {:ok, %{revision: revision, packet: packet, state: :active} = current} <-
             active_read(account, deadline),
           {:ok, replacement} <- fun.(packet) do
        if replacement == packet do
          {:ok, current}
        else
          case Retained.cas(account.ledger, account.key, revision, replacement, deadline) do
            {:ok, entry} -> {:ok, %{revision: entry.revision, packet: entry.checkpoint}}
            {:error, :stale_revision} -> update(account, fun, deadline)
            {:error, _} = error -> error
          end
        end
      end
    end)
  end

  defp active_read(account, deadline) do
    case read(account, deadline) do
      {:ok, %{state: :active} = snapshot} -> {:ok, snapshot}
      {:ok, _} -> {:error, :budget_account_closed}
      error -> error
    end
  end

  # Initialization records only counter state, never external dispatch. Its
  # deterministic attempt can safely finish an interrupted initialization.
  defp initialize(account, %{status: {:checkpointed, _, @attempt}}, deadline),
    do: ensure_readable(account, deadline)

  defp initialize(account, %{status: {:intended}}, deadline) do
    case Retained.record_attempt(account.ledger, account.key, @attempt, deadline) do
      :ok ->
        with {:ok, entry} <- Retained.read(account.ledger, account.key, deadline),
             do: initialize(account, entry, deadline)

      {:error, :checkpoint_active} ->
        ensure_readable(account, deadline)

      {:error, _} = error ->
        error
    end
  end

  defp initialize(account, %{status: {:dispatched, @attempt}} = entry, deadline) do
    packet = Map.merge(entry.recovery, %{"effects_used" => 0, "model_requests_used" => 0})

    case Retained.record_checkpoint(account.ledger, account.key, @attempt, packet, deadline) do
      :ok -> :ok
      {:error, :checkpoint_active} -> ensure_readable(account, deadline)
      {:error, _} = error -> error
    end
  end

  defp initialize(_, _, _), do: {:error, :budget_account_not_active}

  defp ensure_readable(account, deadline) do
    with {:ok, _} <- read(account, deadline), do: :ok
  end

  defp valid_initial(%{tool: @kind, recovery: initial}) when is_map(initial) do
    if Enum.sort(Map.keys(initial)) == Enum.sort(["kind", "version", "generation" | @limits]) and
         initial["kind"] == @kind and initial["version"] == 1 and
         is_binary(initial["generation"]) and byte_size(initial["generation"]) == 32 and
         Enum.all?(@limits, &valid_cap?(initial[&1])),
       do: :ok,
       else: {:error, :invalid_budget_account}
  end

  defp valid_initial(_), do: {:error, :invalid_budget_account}

  defp valid_packet(packet, initial) when is_map(packet) do
    fields = ["kind", "version", "generation"]

    if Enum.sort(Map.keys(packet)) == Enum.sort(fields ++ @limits ++ @counters) and
         Map.take(packet, fields) == Map.take(initial, fields) and
         Enum.all?(@limits, &(valid_cap?(packet[&1]) and packet[&1] <= initial[&1])) and
         Enum.all?(Enum.zip(@counters, @limits), fn {counter, cap} ->
           is_integer(packet[counter]) and packet[counter] >= 0 and
             packet[counter] <= initial[cap]
         end),
       do: :ok,
       else: {:error, :invalid_budget_account}
  end

  defp valid_packet(_, _), do: {:error, :invalid_budget_account}

  defp lifecycle(%{status: {:checkpointed, _, @attempt}}), do: {:ok, :active}

  defp lifecycle(
         %{
           checkpoint_decision: %{"action" => "close_budget", "generation" => generation},
           recovery: %{"generation" => generation},
           checkpoint: packet
         } = entry
       ) do
    case entry.status do
      {:intended} ->
        {:ok, :closing}

      {:dispatched, @close} ->
        {:ok, :closing}

      {:decided, :completed, evidence} ->
        if evidence == Map.take(packet, @limits ++ @counters),
          do: {:ok, :closed},
          else: {:error, :invalid_budget_account}

      _ ->
        {:error, :invalid_budget_account}
    end
  end

  defp lifecycle(_), do: {:error, :invalid_budget_account}

  defp limits(opts) do
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

  defp deadline_option(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) in [[], [:deadline]] do
      deadline = Keyword.get(opts, :deadline, :infinity)

      case Retained.deadline_ok(deadline) do
        :ok -> {:ok, deadline}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_budget_account_options}
    end
  end

  defp valid_cap?(value), do: is_integer(value) and value >= 1 and value <= @max

  defp safe(fun) do
    fun.()
  catch
    :exit, {:timeout, _reason} -> {:error, :run_timeout}
    :exit, reason -> {:error, {:budget_account_unavailable, reason}}
  end
end
