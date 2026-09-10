defmodule Alto.Subagents.Journal do
  @moduledoc """
  Durable child dispatch and retained join results on an `Alto.OperationLog`.

  A batch remains a nonterminal checkpoint, including after every child has
  finished. Only an explicit join acknowledgement and retirement make it
  eligible for ledger eviction. Dispatch grants are single-use: uncertainty
  never grants permission to repeat a child. This module stores lifecycle
  records; the host still owns execution, authority, budgets and recovery.
  """
  alias Alto.OperationLog
  alias Alto.Runner.Checkpoint

  @enforce_keys [:ledger, :key, :generation]
  defstruct [:ledger, :key, :generation]

  defmodule Ticket do
    @moduledoc "A dispatch identity returned only after durable admission."
    @enforce_keys [:batch, :id, :attempt]
    defstruct [:batch, :id, :attempt]
  end

  @kind "alto_subagent_batch"
  @initialize "initialize-batch"
  @retire "retire-batch"
  @max_result_bytes 64_000

  @doc "Create or reconnect an ordered batch with immutable JSON metadata."
  def open(ledger, key, ids, metadata \\ %{}) do
    with :ok <- valid_plan(ids, metadata) do
      initial = %{
        "kind" => @kind,
        "version" => 1,
        "generation" => nonce(),
        "ids" => ids,
        "metadata" => metadata
      }

      safe(fn ->
        with {:ok, entry} <- ensure_intent(ledger, key, initial),
             :ok <- valid_initial(entry),
             true <- entry.recovery["ids"] == ids and entry.recovery["metadata"] == metadata,
             batch = %__MODULE__{
               ledger: ledger,
               key: key,
               generation: entry.recovery["generation"]
             },
             :ok <- initialize(batch, entry),
             {:ok, _} <- read(batch) do
          {:ok, batch}
        else
          false -> {:error, :batch_plan_conflict}
          {:error, _} = error -> error
        end
      end)
    end
  end

  @doc "Portable binding. Keep its generation when reconnecting a saved parent."
  def identity(%__MODULE__{key: key, generation: generation}),
    do: %{"key" => key, "generation" => generation}

  @doc "Reconnect by saved identity without creating a missing or replaced batch."
  def restore(ledger, %{"key" => key, "generation" => generation} = identity)
      when map_size(identity) == 2 and is_binary(key) and is_binary(generation) do
    batch = %__MODULE__{ledger: ledger, key: key, generation: generation}
    with {:ok, _} <- read(batch), do: {:ok, batch}
  end

  def restore(_, _), do: {:error, :invalid_batch_identity}

  @doc "Read an exact retained packet and its revision, including retirement state."
  def read(%__MODULE__{} = batch) do
    safe(fn ->
      with {:ok, entry} <- OperationLog.recovery(batch.ledger, batch.key),
           :ok <- valid_initial(entry),
           true <- entry.recovery["generation"] == batch.generation,
           :ok <- valid_packet(entry.checkpoint, entry.recovery),
           {:ok, state} <- lifecycle(entry) do
        {:ok, %{revision: entry.revision, packet: entry.checkpoint, state: state}}
      else
        false -> {:error, :batch_generation_mismatch}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Persist a single dispatch grant. A repeated call never reissues permission."
  def dispatch(%__MODULE__{} = batch, id) do
    attempt = nonce()

    with {:ok, _} <-
           change_child(batch, id, fn
             %{"state" => "planned"} = child ->
               {:ok, %{child | "state" => "dispatched", "attempt" => attempt}}

             _ ->
               {:error, :child_already_admitted}
           end) do
      {:ok, %Ticket{batch: batch, id: id, attempt: attempt}}
    end
  end

  @doc "Retain an exact portable result before the worker reports completion."
  def complete(%Ticket{batch: batch, id: id, attempt: attempt}, result) do
    with {:ok, encoded} <- encode_result(result) do
      change_child(batch, id, fn
        %{"state" => "dispatched", "attempt" => ^attempt} = child ->
          {:ok, %{child | "state" => "completed", "result" => encoded}}

        %{"state" => "completed", "attempt" => ^attempt, "result" => ^encoded} = child ->
          {:ok, child}

        _ ->
          {:error, :child_result_conflict}
      end)
    end
  end

  @doc "Record known non-dispatch (for example cancellation of a queued child)."
  def skip(%__MODULE__{} = batch, id, result) do
    with {:ok, encoded} <- encode_result(result) do
      change_child(batch, id, fn
        %{"state" => "planned"} = child ->
          {:ok, %{child | "state" => "completed", "result" => encoded}}

        %{"state" => "completed", "attempt" => nil, "result" => ^encoded} = child ->
          {:ok, child}

        _ ->
          {:error, :child_already_admitted}
      end)
    end
  end

  @doc "Read ordered results when every child has a retained outcome. Never dispatches."
  def join(%__MODULE__{} = batch) do
    with {:ok, snapshot} <- read(batch),
         {:ok, results} <- decode_results(snapshot.packet["children"]) do
      {:ok, Map.put(snapshot, :results, results)}
    end
  end

  @doc "Acknowledge a join only after its consumer has durably saved the continuation."
  def acknowledge(%__MODULE__{} = batch, expected_revision, receipt) do
    with true <- is_map(receipt) and map_size(receipt) > 0 and json?(receipt),
         {:ok, snapshot} <- join(batch),
         :ok <- active(snapshot),
         true <- snapshot.revision == expected_revision,
         true <- is_nil(snapshot.packet["join"]) do
      replace(batch, snapshot, Map.put(snapshot.packet, "join", receipt))
    else
      false -> {:error, :invalid_or_stale_join}
      {:error, _} = error -> error
    end
  end

  @doc "Retire an acknowledged batch at its viewed revision. Never discards unjoined work."
  def retire(%__MODULE__{} = batch, expected_revision) do
    safe(fn ->
      with {:ok, snapshot} <- read(batch),
           true <- snapshot.revision == expected_revision,
           true <- is_map(snapshot.packet["join"]),
           :ok <- begin_retirement(batch, snapshot),
           :ok <- finish_retirement(batch) do
        :ok
      else
        false -> {:error, :invalid_or_stale_join}
        {:error, _} = error -> error
      end
    end)
  end

  defp change_child(batch, id, fun) do
    update(batch, fn packet ->
      with true <- is_nil(packet["join"]),
           index when is_integer(index) <- Enum.find_index(packet["children"], &(&1["id"] == id)),
           {:ok, child} <- fun.(Enum.at(packet["children"], index)) do
        {:ok, Map.update!(packet, "children", &List.replace_at(&1, index, child))}
      else
        false -> {:error, :batch_already_joined}
        nil -> {:error, :unknown_child}
        {:error, _} = error -> error
      end
    end)
  end

  defp update(batch, fun) do
    with {:ok, snapshot} <- read(batch),
         :ok <- active(snapshot),
         {:ok, packet} <- fun.(snapshot.packet) do
      if packet == snapshot.packet do
        {:ok, snapshot}
      else
        case replace(batch, snapshot, packet) do
          {:error, :stale_revision} -> update(batch, fun)
          other -> other
        end
      end
    end
  end

  defp replace(batch, snapshot, packet) do
    safe(fn ->
      with {:ok, entry} <-
             OperationLog.update_checkpoint(batch.ledger, batch.key, snapshot.revision, packet) do
        {:ok, %{revision: entry.revision, packet: entry.checkpoint, state: :active}}
      end
    end)
  end

  defp active(%{state: :active}), do: :ok
  defp active(_), do: {:error, :batch_not_active}

  defp decode_results(children) do
    # A fresh observer need not have executed the runner. Load the fixed Alto
    # result vocabulary before safe ETF decoding; never load modules named by
    # a stored value or create atoms from stored data.
    Code.ensure_loaded!(Alto.Runner.Serial)
    Code.ensure_loaded!(Alto.Usage)

    Enum.reduce_while(children, {:ok, []}, fn child, {:ok, results} ->
      case child do
        %{"state" => "completed", "id" => id, "result" => encoded} ->
          case Checkpoint.decode(encoded) do
            {:ok, value} -> {:cont, {:ok, [{id, value} | results]}}
            {:error, _} = error -> {:halt, error}
          end

        %{"state" => state, "id" => id} ->
          {:halt, {:error, {:child_pending, id, state}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp encode_result(result) do
    if :erlang.external_size(result) <= @max_result_bytes,
      do: Checkpoint.encode(result),
      else: {:error, {:child_result_too_large, @max_result_bytes}}
  rescue
    _ -> {:error, :checkpoint_not_portable_or_too_large}
  end

  defp ensure_intent(ledger, key, initial) do
    case OperationLog.recovery(ledger, key) do
      {:error, :not_found} ->
        case OperationLog.record_intent(ledger, key, @kind, nil, initial) do
          :ok -> OperationLog.recovery(ledger, key)
          {:error, :intent_conflict} -> OperationLog.recovery(ledger, key)
          error -> error
        end

      other ->
        other
    end
  end

  defp initialize(_batch, %{checkpoint: packet}) when is_map(packet), do: :ok

  defp initialize(batch, %{status: {:intended}}) do
    case OperationLog.record_attempt(batch.ledger, batch.key, @initialize) do
      :ok ->
        with {:ok, entry} <- OperationLog.recovery(batch.ledger, batch.key),
             do: initialize(batch, entry)

      {:error, :checkpoint_active} ->
        :ok

      error ->
        error
    end
  end

  defp initialize(batch, %{status: {:dispatched, @initialize}, recovery: initial}) do
    children =
      Enum.map(
        initial["ids"],
        &%{"id" => &1, "state" => "planned", "attempt" => nil, "result" => nil}
      )

    packet = Map.merge(initial, %{"children" => children, "join" => nil})

    case OperationLog.record_checkpoint(batch.ledger, batch.key, @initialize, packet) do
      :ok -> :ok
      {:error, :checkpoint_active} -> :ok
      error -> error
    end
  end

  defp initialize(_, _), do: {:error, :invalid_batch_state}

  defp begin_retirement(batch, %{state: :active} = snapshot) do
    with {:ok, _} <-
           OperationLog.resume_checkpoint(batch.ledger, batch.key, snapshot.revision, %{
             "action" => @retire,
             "generation" => batch.generation
           }),
         do: :ok
  end

  defp begin_retirement(_, %{state: state}) when state in [:retiring, :retired], do: :ok

  # No external work occurs during retirement. A crash can finish these same
  # deterministic ledger records without replaying or releasing a child.
  defp finish_retirement(batch) do
    with {:ok, snapshot} <- read(batch) do
      if snapshot.state == :retired do
        :ok
      else
        with :ok <- OperationLog.record_attempt(batch.ledger, batch.key, @retire),
             :ok <-
               OperationLog.record_outcome(batch.ledger, batch.key, @retire, :completed, %{
                 "generation" => batch.generation,
                 "joined" => true
               }),
             do: :ok
      end
    end
  end

  defp lifecycle(%{status: {:checkpointed, _, @initialize}}), do: {:ok, :active}

  defp lifecycle(
         %{
           checkpoint_decision: %{"action" => @retire, "generation" => generation},
           recovery: %{"generation" => generation}
         } = entry
       ) do
    if is_map(entry.checkpoint["join"]) do
      case entry.status do
        {:intended} ->
          {:ok, :retiring}

        {:dispatched, @retire} ->
          {:ok, :retiring}

        {:decided, :completed, %{"generation" => ^generation, "joined" => true}} ->
          {:ok, :retired}

        _ ->
          {:error, :invalid_batch_state}
      end
    else
      {:error, :invalid_batch_state}
    end
  end

  defp lifecycle(_), do: {:error, :invalid_batch_state}

  defp valid_initial(%{tool: @kind, recovery: initial}) when is_map(initial) do
    if Enum.sort(Map.keys(initial)) == Enum.sort(~w(kind version generation ids metadata)) and
         initial["kind"] == @kind and initial["version"] == 1 and nonce?(initial["generation"]) do
      valid_plan(initial["ids"], initial["metadata"])
    else
      {:error, :invalid_batch}
    end
  end

  defp valid_initial(_), do: {:error, :invalid_batch}

  defp valid_packet(packet, initial) when is_map(packet) do
    if Map.drop(packet, ["children", "join"]) == initial and
         map_size(packet) == map_size(initial) + 2 and
         is_list(packet["children"]) and
         Enum.all?(packet["children"], &valid_child?/1) and
         Enum.map(packet["children"], & &1["id"]) == initial["ids"] and
         (is_nil(packet["join"]) or
            (is_map(packet["join"]) and map_size(packet["join"]) > 0 and
               Enum.all?(packet["children"], &(&1["state"] == "completed")))) do
      :ok
    else
      {:error, :invalid_batch}
    end
  end

  defp valid_packet(_, _), do: {:error, :invalid_batch}

  defp valid_child?(
         %{"id" => id, "state" => state, "attempt" => attempt, "result" => result} = child
       )
       when map_size(child) == 4 do
    valid_id?(id) and
      case state do
        "planned" ->
          is_nil(attempt) and is_nil(result)

        "dispatched" ->
          nonce?(attempt) and is_nil(result)

        "completed" ->
          (is_nil(attempt) or nonce?(attempt)) and is_binary(result) and
            byte_size(result) <= div(@max_result_bytes * 4, 3) + 8

        _ ->
          false
      end
  end

  defp valid_child?(_), do: false

  defp valid_plan(ids, metadata) do
    if is_list(ids) and length(ids) in 1..64 and Enum.all?(ids, &valid_id?/1) and
         Enum.uniq(ids) == ids and is_map(metadata) and json?(metadata),
       do: :ok,
       else: {:error, :invalid_batch_plan}
  end

  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id)
  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp nonce?(value),
    do: is_binary(value) and byte_size(value) == 32 and String.match?(value, ~r/\A[0-9a-f]+\z/)

  defp json?(value) do
    :erlang.external_size(value) <= 64_000 and JSON.decode(JSON.encode!(value)) == {:ok, value}
  rescue
    _ -> false
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:subagent_journal_unavailable, reason}}
  end
end
