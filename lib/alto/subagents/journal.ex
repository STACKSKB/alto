defmodule Alto.Subagents.Journal do
  @moduledoc """
  Durable child dispatch and retained join results on an `Alto.OperationLog`.

  A batch remains a nonterminal checkpoint, including after every child has
  finished. Only an explicit join acknowledgement and retirement make it
  eligible for ledger eviction. Dispatch grants are single-use: uncertainty
  never grants permission to repeat a child. This module stores lifecycle
  records; the host still owns execution, authority, budgets and recovery.
  """
  alias Alto.Persistence.Codec
  alias Alto.Persistence.Retained

  @enforce_keys [:ledger, :key, :generation]
  defstruct [:ledger, :key, :generation, deadline: :infinity]

  defmodule Ticket do
    @moduledoc "A dispatch identity returned only after durable admission."
    @enforce_keys [:batch, :id, :attempt]
    defstruct [:batch, :id, :attempt, :suspension, :grant]
  end

  @kind "alto_subagent_batch"
  @initialize "initialize-batch"
  @retire "retire-batch"
  @max_result_bytes 64_000
  @max_checkpoint_bytes 2_000_000

  @doc "Create or reconnect an ordered batch with immutable JSON metadata."
  def open(ledger, key, ids, metadata \\ %{}, opts \\ []) do
    with :ok <- valid_plan(ids, metadata) do
      initial = %{
        "kind" => @kind,
        "version" => 1,
        "generation" => nonce(),
        "ids" => ids,
        "metadata" => metadata
      }

      safe(fn ->
        with :ok <- Retained.deadline_ok(Keyword.get(opts, :deadline, :infinity)),
             {:ok, entry} <-
               Retained.ensure_intent(
                 ledger,
                 key,
                 @kind,
                 nil,
                 initial,
                 Keyword.get(opts, :deadline, :infinity)
               ),
             :ok <- valid_initial(entry),
             true <- entry.recovery["ids"] == ids and entry.recovery["metadata"] == metadata,
             batch = %__MODULE__{
               ledger: ledger,
               key: key,
               generation: entry.recovery["generation"],
               deadline: Keyword.get(opts, :deadline, :infinity)
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
  def restore(ledger, identity, opts \\ [])

  def restore(ledger, %{"key" => key, "generation" => generation} = identity, opts)
      when map_size(identity) == 2 and is_binary(key) and is_binary(generation) do
    batch = %__MODULE__{
      ledger: ledger,
      key: key,
      generation: generation,
      deadline: Keyword.get(opts, :deadline, :infinity)
    }

    with {:ok, _} <- read(batch), do: {:ok, batch}
  end

  def restore(_, _, _), do: {:error, :invalid_batch_identity}

  @doc "Read an exact retained packet and its revision, including retirement state."
  def read(%__MODULE__{} = batch) do
    safe(fn ->
      with {:ok, entry} <-
             Retained.read(batch.ledger, batch.key, batch.deadline),
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
  def complete(%Ticket{} = ticket, result) do
    with {:ok, encoded} <- encode_result(result) do
      change_child(ticket.batch, ticket.id, fn child ->
        cond do
          owns_dispatch?(child, ticket) ->
            {:ok,
             child
             |> Map.drop(["suspension"])
             |> Map.merge(%{"state" => "completed", "result" => encoded})}

          child["state"] == "completed" and child["attempt"] == ticket.attempt and
              child["result"] == encoded ->
            {:ok, child}

          true ->
            {:error, :child_result_conflict}
        end
      end)
    end
  end

  @doc "Retain an exact approval checkpoint before a child reports suspension."
  def suspend(%Ticket{} = ticket, checkpoint, workspace \\ nil) do
    with {:ok, encoded} <-
           Codec.encode(%{"checkpoint" => checkpoint, "workspace" => workspace},
             max_bytes: @max_checkpoint_bytes
           ) do
      change_child(ticket.batch, ticket.id, fn child ->
        if owns_dispatch?(child, ticket) do
          {:ok,
           Map.merge(child, %{
             "state" => "suspended",
             "suspension" => %{
               "token" => nonce(),
               "checkpoint" => encoded,
               "decision" => nil,
               "grant" => nil
             }
           })}
        else
          {:error, :child_result_conflict}
        end
      end)
    end
  end

  @doc "Inspect retained approvals and explicit decisions without granting execution."
  def suspended(%__MODULE__{} = batch) do
    with {:ok, snapshot} <- read(batch) do
      Enum.reduce_while(snapshot.packet["children"], {:ok, []}, fn child, {:ok, acc} ->
        if child["state"] in ["suspended", "decided"] do
          with {:ok, saved} <-
                 Codec.decode(child["suspension"]["checkpoint"], max_bytes: @max_checkpoint_bytes) do
            entry =
              Map.merge(%{checkpoint: saved["checkpoint"], workspace: saved["workspace"]}, %{
                id: child["id"],
                state: if(child["state"] == "suspended", do: :suspended, else: :decided),
                identity: child_identity(batch, child),
                decision: child["suspension"]["decision"]
              })

            {:cont, {:ok, [entry | acc]}}
          else
            error -> {:halt, error}
          end
        else
          {:cont, {:ok, acc}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    end
  end

  @doc "Persist an explicit approval decision at the exact viewed batch revision."
  def decide(%__MODULE__{} = batch, revision, identity, decision)
      when decision in [:approve, :deny] do
    with {:ok, snapshot} <- read(batch),
         :ok <- active(snapshot),
         true <- snapshot.revision == revision,
         child when not is_nil(child) <-
           Enum.find(snapshot.packet["children"], &(child_identity(batch, &1) == identity)),
         true <- child["state"] == "suspended" and is_nil(snapshot.packet["join"]) do
      children =
        Enum.map(snapshot.packet["children"], fn current ->
          if current == child,
            do:
              current
              |> Map.put("state", "decided")
              |> put_in(["suspension", "decision"], Atom.to_string(decision)),
            else: current
        end)

      replace(batch, snapshot, Map.put(snapshot.packet, "children", children))
    else
      false -> {:error, :stale_child_decision}
      nil -> {:error, :stale_child_decision}
      {:error, _} = error -> error
    end
  end

  def decide(_, _, _, _), do: {:error, :invalid_child_decision}

  @doc "Grant one decided checkpoint after the runner validates its complete restore."
  def claim_child(%__MODULE__{} = batch, identity, decision) when decision in [:approve, :deny] do
    ticket = resume_ticket(batch, identity)
    with {:ok, _} <- claim_child(ticket, identity, decision), do: {:ok, ticket}
  end

  def claim_child(%Ticket{batch: batch, grant: grant} = ticket, identity, decision)
      when decision in [:approve, :deny] do
    change_child(batch, ticket.id, fn child ->
      if child_identity(batch, child) == identity and child["state"] == "decided" and
           child["suspension"]["decision"] == Atom.to_string(decision) and nonce?(grant) do
        {:ok, child |> Map.put("state", "resuming") |> put_in(["suspension", "grant"], grant)}
      else
        {:error, :child_resume_not_granted}
      end
    end)
  end

  @doc false
  def resume_ticket(batch, identity) do
    %Ticket{
      batch: batch,
      id: identity["id"],
      attempt: identity["attempt"],
      suspension: identity["suspension"],
      grant: nonce()
    }
  end

  defp child_identity(batch, child) do
    %{
      "journal" => identity(batch),
      "id" => child["id"],
      "attempt" => child["attempt"],
      "suspension" => get_in(child, ["suspension", "token"])
    }
  end

  defp owns_dispatch?(%{"state" => "dispatched", "attempt" => attempt}, %Ticket{
         attempt: attempt,
         suspension: nil
       }),
       do: true

  defp owns_dispatch?(
         %{
           "state" => "resuming",
           "attempt" => attempt,
           "suspension" => %{"token" => token, "grant" => grant}
         },
         %Ticket{attempt: attempt, suspension: token, grant: grant}
       ),
       do: true

  defp owns_dispatch?(_, _), do: false

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
             Retained.cas(batch.ledger, batch.key, snapshot.revision, packet, batch.deadline) do
        {:ok, %{revision: entry.revision, packet: entry.checkpoint, state: :active}}
      end
    end)
  end

  defp active(%{state: :active}), do: :ok
  defp active(_), do: {:error, :batch_not_active}

  defp decode_results(children) do
    Enum.reduce_while(children, {:ok, []}, fn child, {:ok, results} ->
      case child do
        %{"state" => "completed", "id" => id, "result" => encoded} ->
          case Codec.decode(encoded, max_bytes: @max_result_bytes) do
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
    case Codec.encode(result, max_bytes: @max_result_bytes) do
      {:ok, encoded} ->
        {:ok, encoded}

      {:error, :not_portable_or_too_large} ->
        if portable_size?(result),
          do: {:error, :checkpoint_not_portable_or_too_large},
          else: {:error, {:child_result_too_large, @max_result_bytes}}
    end
  rescue
    _ -> {:error, :checkpoint_not_portable_or_too_large}
  end

  defp initialize(_batch, %{checkpoint: packet}) when is_map(packet), do: :ok

  defp initialize(batch, %{status: {:intended}}) do
    case Retained.record_attempt(batch.ledger, batch.key, @initialize, batch.deadline) do
      :ok ->
        with {:ok, entry} <- Retained.read(batch.ledger, batch.key, batch.deadline),
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

    case Retained.record_checkpoint(
           batch.ledger,
           batch.key,
           @initialize,
           packet,
           batch.deadline
         ) do
      :ok -> :ok
      {:error, :checkpoint_active} -> :ok
      error -> error
    end
  end

  defp initialize(_, _), do: {:error, :invalid_batch_state}

  defp begin_retirement(batch, %{state: :active} = snapshot) do
    with {:ok, _} <-
           Retained.resume(
             batch.ledger,
             batch.key,
             snapshot.revision,
             %{
               "action" => @retire,
               "generation" => batch.generation
             },
             batch.deadline
           ),
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
        with :ok <-
               Retained.record_attempt(batch.ledger, batch.key, @retire, batch.deadline),
             :ok <-
               Retained.record_outcome(
                 batch.ledger,
                 batch.key,
                 @retire,
                 :completed,
                 %{
                   "generation" => batch.generation,
                   "joined" => true
                 },
                 batch.deadline
               ),
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

  defp valid_child?(
         %{
           "id" => id,
           "state" => state,
           "attempt" => attempt,
           "result" => nil,
           "suspension" => suspension
         } = child
       )
       when map_size(child) == 5 and state in ["suspended", "decided", "resuming"] do
    valid_id?(id) and nonce?(attempt) and is_map(suspension) and
      Enum.sort(Map.keys(suspension)) == Enum.sort(~w(token checkpoint decision grant)) and
      nonce?(suspension["token"]) and
      if(state == "resuming", do: nonce?(suspension["grant"]), else: is_nil(suspension["grant"])) and
      is_binary(suspension["checkpoint"]) and
      byte_size(suspension["checkpoint"]) <= div(@max_checkpoint_bytes * 4, 3) + 8 and
      if(state == "suspended",
        do: is_nil(suspension["decision"]),
        else: suspension["decision"] in ["approve", "deny"]
      )
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

  defp portable_size?(term) do
    :erlang.external_size(term) <= @max_result_bytes
  rescue
    _ -> false
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, {:timeout, _reason} -> {:error, :run_timeout}
    :exit, reason -> {:error, {:subagent_journal_unavailable, reason}}
  end
end
