defmodule Alto.Subagents.Continuation do
  @moduledoc """
  Durable child dispatch and retained join results on an `Alto.OperationLog`.

  A standalone batch remains a nonterminal checkpoint after every child has
  finished; explicit join acknowledgement and retirement make it eligible for
  ledger eviction. A parent-backed aggregate instead advances atomically from
  `children` to `ready` and then grants its frame once by moving to `claimed`.
  Dispatch and parent grants are single-use: uncertainty never grants permission
  to repeat work. The host still owns execution, authority, budgets and recovery.
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

  @kind "alto_subagent_continuation"
  @initialize "initialize-continuation"
  @retire "retire-continuation"
  @max_result_bytes 64_000
  @max_checkpoint_bytes 2_000_000

  @doc """
  Create or reconnect an ordered batch with immutable portable metadata.
  Pass `parent: checkpoint` to bind a pending parent; an empty child list
  then retains a parent frame without child dependencies.
  """
  def open(ledger, key, ids, metadata \\ %{}, opts \\ []) do
    parent = Keyword.get(opts, :parent)

    with :ok <- valid_key(key), :ok <- valid_plan(ids, metadata, parent) do
      initial = %{
        "kind" => @kind,
        "version" => 3,
        "generation" => nonce(),
        "ids" => ids,
        "metadata" => metadata,
        "parent" => parent
      }

      packet = %{
        "phase" => "children",
        "generation" => initial["generation"],
        "children" => Map.new(ids, &{&1, {:planned}}),
        "join" => nil
      }

      deadline = Keyword.get(opts, :deadline, :infinity)

      safe(fn ->
        with {:ok, entry} <-
               Retained.ensure_checkpoint(
                 ledger,
                 key,
                 @kind,
                 initial,
                 @initialize,
                 packet,
                 deadline
               ),
             :ok <- valid_initial(entry),
             true <-
               entry.recovery["ids"] == ids and entry.recovery["metadata"] == metadata and
                 entry.recovery["parent"] == parent,
             batch = %__MODULE__{
               ledger: ledger,
               key: key,
               generation: entry.recovery["generation"],
               deadline: deadline
             },
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

  @doc "Read and validate an existing batch without initializing or mutating it."
  def lookup(ledger, key, opts \\ []) do
    with {:ok, deadline} <- Retained.deadline(opts),
         :ok <- valid_key(key) do
      safe(fn ->
        with {:ok, entry} <- Retained.read(ledger, key, deadline),
             :ok <- valid_initial(entry),
             batch = %__MODULE__{
               ledger: ledger,
               key: key,
               generation: entry.recovery["generation"],
               deadline: deadline
             },
             {:ok, snapshot} <- snapshot(entry, batch.generation) do
          {:ok, batch, snapshot}
        end
      end)
    else
      {:error, _} = error -> error
    end
  end

  @doc "List aggregate continuations whose immutable metadata contains the filter."
  def list(ledger, metadata_filter \\ %{}, opts \\ []) do
    with true <- is_map(metadata_filter) and Codec.valid?(metadata_filter, max_bytes: 64_000),
         {:ok, deadline} <- Retained.deadline(opts) do
      safe(fn -> list_entries(ledger, metadata_filter, deadline) end)
    else
      false -> {:error, :invalid_continuation_metadata_filter}
      {:error, _} = error -> error
    end
  end

  defp list_entries(ledger, metadata_filter, deadline) do
    with entries when is_list(entries) <- Retained.entries(ledger, deadline),
         {:ok, items} <-
           entries
           |> Enum.filter(&(&1.tool == @kind))
           |> Enum.sort_by(& &1.operation_key)
           |> Alto.Result.traverse(&listed_entry/1) do
      {:ok,
       Enum.filter(items, fn item ->
         Enum.all?(metadata_filter, fn {key, value} ->
           Map.fetch(item.snapshot.metadata, key) == {:ok, value}
         end)
       end)}
    end
  end

  defp listed_entry(entry) do
    with :ok <- valid_initial(entry),
         {:ok, snapshot} <- snapshot(entry, entry.recovery["generation"]) do
      {:ok,
       %{
         identity: %{"key" => entry.operation_key, "generation" => entry.recovery["generation"]},
         snapshot: snapshot
       }}
    end
  end

  @doc "Read an exact retained packet and its revision, including retirement state."
  def read(%__MODULE__{} = batch) do
    safe(fn -> snapshot_read(batch) end)
  end

  @doc "Inspect one approval from a single validated batch snapshot."
  def inspect_approval(%__MODULE__{} = batch, expected_revision, child_id) do
    with :ok <- valid_revision(expected_revision),
         :ok <- valid_approval_child_id(child_id),
         {:ok, snapshot} <- read(batch),
         true <- snapshot.revision == expected_revision,
         child when not is_nil(child) <-
           Map.get(snapshot.packet["children"], child_id),
         true <- elem(child, 0) in [:suspended, :decided] do
      {:ok, Map.put(approval_view(batch, child_id, child), :revision, snapshot.revision)}
    else
      false -> {:error, :stale_child_approval}
      nil -> {:error, :unknown_child}
      {:error, _} = error -> error
    end
  end

  @doc "Persist a single dispatch grant. A repeated call never reissues permission."
  def dispatch(%__MODULE__{} = batch, id) do
    attempt = nonce()

    with {:ok, _} <-
           change_child(batch, id, fn
             {:planned} ->
               {:ok, {:dispatched, attempt}}

             _ ->
               {:error, :child_already_admitted}
           end) do
      {:ok, %Ticket{batch: batch, id: id, attempt: attempt}}
    end
  end

  @doc "Retain an exact portable result before the worker reports completion."
  def complete(%Ticket{} = ticket, result) do
    with :ok <- validate_result(result) do
      change_child(ticket.batch, ticket.id, fn child ->
        cond do
          owns_dispatch?(child, ticket) ->
            {:ok, {:completed, ticket.attempt, result}}

          child === {:completed, ticket.attempt, result} ->
            {:ok, child}

          true ->
            {:error, :child_result_conflict}
        end
      end)
    end
  end

  @doc "Retain an exact approval checkpoint before a child reports suspension."
  def suspend(%Ticket{} = ticket, checkpoint, workspace \\ nil) do
    saved = %{"checkpoint" => checkpoint, "workspace" => workspace}

    if valid_suspension?(saved) do
      change_child(ticket.batch, ticket.id, fn child ->
        if owns_dispatch?(child, ticket) do
          {:ok, {:suspended, ticket.attempt, nonce(), saved}}
        else
          {:error, :child_result_conflict}
        end
      end)
    else
      {:error, :not_portable_or_too_large}
    end
  end

  @doc "Inspect retained approvals and explicit decisions without granting execution."
  def suspended(%__MODULE__{} = batch) do
    with {:ok, snapshot} <- read(batch) do
      snapshot.ids
      |> Enum.filter(&(elem(snapshot.packet["children"][&1], 0) in [:suspended, :decided]))
      |> Enum.map(&approval_view(batch, &1, snapshot.packet["children"][&1]))
      |> then(&{:ok, &1})
    end
  end

  @doc "Persist an explicit approval decision at the exact viewed batch revision."
  def decide(%__MODULE__{} = batch, revision, identity, decision)
      when is_map(identity) and decision in [:approve, :deny] do
    with {:ok, snapshot} <- read(batch),
         :ok <- active(snapshot),
         true <- snapshot.revision == revision,
         {:suspended, attempt, token, saved} <-
           Map.get(snapshot.packet["children"], identity["id"]),
         true <- child_identity(batch, identity["id"], attempt, token) == identity,
         true <- is_nil(snapshot.packet["join"]) do
      child = {:decided, attempt, token, saved, decision}
      replace(batch, snapshot, put_in(snapshot.packet, ["children", identity["id"]], child))
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_child_decision}
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
    change_child(batch, ticket.id, fn
      {:decided, attempt, token, saved, ^decision} ->
        if child_identity(batch, ticket.id, attempt, token) == identity and nonce?(grant),
          do: {:ok, {:resuming, attempt, token, saved, decision, grant}},
          else: {:error, :child_resume_not_granted}

      _ ->
        {:error, :child_resume_not_granted}
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

  defp child_identity(batch, id, attempt, token) do
    %{
      "journal" => identity(batch),
      "id" => id,
      "attempt" => attempt,
      "suspension" => token
    }
  end

  defp owns_dispatch?({:dispatched, attempt}, %Ticket{attempt: attempt, suspension: nil}),
    do: true

  defp owns_dispatch?(
         {:resuming, attempt, token, _saved, _decision, grant},
         %Ticket{attempt: attempt, suspension: token, grant: grant}
       ),
       do: true

  defp owns_dispatch?(_, _), do: false

  @doc "Record known non-dispatch (for example cancellation of a queued child)."
  def skip(%__MODULE__{} = batch, id, result) do
    with :ok <- validate_result(result) do
      change_child(batch, id, fn
        {:planned} ->
          {:ok, {:completed, nil, result}}

        {:completed, nil, ^result} = child ->
          {:ok, child}

        _ ->
          {:error, :child_already_admitted}
      end)
    end
  end

  @doc "Read ordered results when every child has a retained outcome. Never dispatches."
  def join(%__MODULE__{} = batch) do
    with {:ok, snapshot} <- read(batch),
         {:ok, results} <- ordered_results(snapshot.ids, snapshot.packet["children"]) do
      {:ok, Map.put(snapshot, :results, results)}
    end
  end

  @doc "Atomically replace a completed child batch with its exact parent continuation."
  def ready(%__MODULE__{} = cell, expected_revision, packet) do
    with :ok <- valid_revision(expected_revision),
         :ok <- valid_parent(packet),
         {:ok, %{phase: :children} = snapshot} <- read(cell),
         :ok <- active(snapshot),
         {:ok, _results} <- ordered_results(snapshot.ids, snapshot.packet["children"]),
         true <- not is_nil(snapshot.parent) and snapshot.revision == expected_revision,
         replacement <- %{
           "phase" => "ready",
           "generation" => cell.generation,
           "packet" => packet,
           "children" => snapshot.packet["children"]
         } do
      replace(cell, snapshot, replacement)
    else
      false -> {:error, :stale_revision}
      {:ok, _} -> {:error, :invalid_continuation_phase}
      {:error, _} = error -> error
    end
  end

  @doc "Claim a ready parent continuation exactly once."
  def claim(%__MODULE__{} = cell, expected_revision) do
    with :ok <- valid_revision(expected_revision),
         {:ok, %{phase: :ready} = snapshot} <- read(cell),
         true <- snapshot.revision == expected_revision do
      replace(cell, snapshot, %{snapshot.packet | "phase" => "claimed"})
    else
      false -> {:error, :stale_revision}
      {:ok, %{phase: :claimed}} -> {:error, :continuation_already_claimed}
      {:ok, _} -> {:error, :invalid_continuation_phase}
      {:error, _} = error -> error
    end
  end

  @doc "Acknowledge a join only after its consumer has durably saved the continuation."
  def acknowledge(%__MODULE__{} = batch, expected_revision, receipt) do
    with true <-
           is_map(receipt) and map_size(receipt) > 0 and Codec.valid?(receipt, max_bytes: 64_000),
         {:ok, snapshot} <- join(batch),
         true <- is_nil(snapshot.parent),
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
           true <- retireable?(snapshot) do
        retire_snapshot(batch, snapshot)
      else
        false -> {:error, :invalid_or_stale_join}
        {:error, _} = error -> error
      end
    end)
  end

  defp change_child(batch, id, fun) do
    update(batch, fn packet ->
      with true <- is_nil(packet["join"]),
           child when not is_nil(child) <- Map.get(packet["children"], id),
           {:ok, child} <- fun.(child) do
        {:ok, put_in(packet, ["children", id], child)}
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
         true <- snapshot.phase == :children,
         {:ok, packet} <- fun.(snapshot.packet) do
      if packet == snapshot.packet do
        {:ok, snapshot}
      else
        case replace(batch, snapshot, packet) do
          {:error, :stale_revision} -> update(batch, fun)
          other -> other
        end
      end
    else
      false -> {:error, :continuation_children_closed}
      {:error, _} = error -> error
    end
  end

  defp replace(batch, snapshot, packet) do
    safe(fn ->
      with {:ok, entry} <-
             Retained.cas(batch.ledger, batch.key, snapshot.revision, packet, batch.deadline) do
        snapshot(entry, batch.generation)
      end
    end)
  end

  defp active(%{state: :active}), do: :ok
  defp active(_), do: {:error, :batch_not_active}

  defp ordered_results(ids, children) do
    Alto.Result.traverse(ids, fn id ->
      case children[id] do
        {:completed, _attempt, result} ->
          {:ok, {id, result}}

        child ->
          {:error, {:child_pending, id, Atom.to_string(elem(child, 0))}}
      end
    end)
  end

  defp validate_result(result) do
    if Codec.valid?(result, max_bytes: @max_result_bytes) do
      :ok
    else
      if portable_size?(result),
        do: {:error, :checkpoint_not_portable_or_too_large},
        else: {:error, {:child_result_too_large, @max_result_bytes}}
    end
  end

  defp retire_snapshot(_, %{state: :retired}), do: :ok

  defp retire_snapshot(batch, %{state: :active} = snapshot) do
    Retained.retire(
      batch.ledger,
      batch.key,
      snapshot.revision,
      %{"action" => @retire, "generation" => batch.generation},
      @retire,
      %{"generation" => batch.generation, "joined" => true},
      batch.deadline
    )
  end

  defp snapshot_read(batch) do
    with {:ok, entry} <- Retained.read(batch.ledger, batch.key, batch.deadline),
         :ok <- valid_initial(entry) do
      snapshot(entry, batch.generation)
    end
  end

  defp snapshot(entry, generation) do
    with true <- entry.recovery["generation"] == generation,
         :ok <- valid_packet(entry.checkpoint, entry.recovery),
         {:ok, state} <- lifecycle(entry) do
      {:ok,
       %{
         revision: entry.revision,
         packet: entry.checkpoint,
         phase: String.to_existing_atom(entry.checkpoint["phase"]),
         metadata: entry.recovery["metadata"],
         parent: entry.recovery["parent"],
         ids: entry.recovery["ids"],
         state: state
       }}
    else
      false -> {:error, :batch_generation_mismatch}
      {:error, _} = error -> error
    end
  end

  defp approval_view(batch, id, {:suspended, attempt, token, saved}),
    do: approval_view(batch, id, {:decided, attempt, token, saved, nil})

  defp approval_view(batch, id, {:decided, attempt, token, saved, decision}) do
    %{
      checkpoint: saved["checkpoint"],
      workspace: saved["workspace"],
      id: id,
      state: if(is_nil(decision), do: :suspended, else: :decided),
      identity: child_identity(batch, id, attempt, token),
      decision: if(decision, do: Atom.to_string(decision))
    }
  end

  defp lifecycle(%{status: {:checkpointed, _, @initialize}}), do: {:ok, :active}

  defp lifecycle(%{
         checkpoint_decision: %{"action" => @retire, "generation" => generation},
         recovery: %{"generation" => generation},
         status: {:decided, :completed, %{"generation" => generation, "joined" => true}},
         checkpoint: packet
       }) do
    if (packet["phase"] == "children" and is_map(packet["join"])) or packet["phase"] == "claimed",
      do: {:ok, :retired},
      else: {:error, :invalid_batch_state}
  end

  defp lifecycle(_), do: {:error, :invalid_batch_state}

  defp valid_initial(%{tool: @kind, recovery: initial}) when is_map(initial) do
    if Enum.sort(Map.keys(initial)) == Enum.sort(~w(kind version generation ids metadata parent)) and
         initial["kind"] == @kind and initial["version"] == 3 and nonce?(initial["generation"]) do
      valid_plan(initial["ids"], initial["metadata"], initial["parent"])
    else
      {:error, :invalid_batch}
    end
  end

  defp valid_initial(_), do: {:error, :invalid_batch}

  defp valid_packet(%{"generation" => generation, "children" => children} = packet, initial)
       when map_size(packet) == 4 and is_map(children) do
    if generation == initial["generation"] and Enum.all?(Map.values(children), &valid_child?/1) and
         MapSet.new(Map.keys(children)) == MapSet.new(initial["ids"]) do
      valid_phase(packet, initial["parent"])
    else
      {:error, :invalid_batch}
    end
  end

  defp valid_packet(_, _), do: {:error, :invalid_batch}

  defp valid_phase(%{"phase" => "children", "join" => nil}, _parent), do: :ok

  defp valid_phase(%{"phase" => "children", "join" => join, "children" => children}, nil)
       when is_map(join) and map_size(join) > 0 do
    if Enum.all?(Map.values(children), &match?({:completed, _, _}, &1)),
      do: :ok,
      else: {:error, :invalid_batch}
  end

  defp valid_phase(%{"phase" => phase, "packet" => packet, "children" => children}, parent)
       when phase in ["ready", "claimed"] and not is_nil(parent) do
    if Enum.all?(Map.values(children), &match?({:completed, _, _}, &1)),
      do: valid_parent(packet),
      else: {:error, :invalid_batch}
  end

  defp valid_phase(_, _), do: {:error, :invalid_batch}

  # Tagged states carry only the data valid at that transition. Decisions and
  # grants cannot appear on planned/dispatched/completed children.
  defp valid_child?({:planned}), do: true
  defp valid_child?({:dispatched, attempt}), do: nonce?(attempt)

  defp valid_child?({:completed, attempt, result}),
    do:
      (is_nil(attempt) or nonce?(attempt)) and Codec.valid?(result, max_bytes: @max_result_bytes)

  defp valid_child?({:suspended, attempt, token, saved}),
    do: nonce?(attempt) and nonce?(token) and valid_suspension?(saved)

  defp valid_child?({:decided, attempt, token, saved, decision}),
    do: decision in [:approve, :deny] and valid_child?({:suspended, attempt, token, saved})

  defp valid_child?({:resuming, attempt, token, saved, decision, grant}),
    do: nonce?(grant) and valid_child?({:decided, attempt, token, saved, decision})

  defp valid_child?(_), do: false

  defp valid_suspension?(%{"checkpoint" => _, "workspace" => _} = saved)
       when map_size(saved) == 2,
       do: Codec.valid?(saved, max_bytes: @max_checkpoint_bytes)

  defp valid_suspension?(_), do: false

  defp valid_plan(ids, metadata, parent) do
    if is_list(ids) and length(ids) <= 64 and (ids != [] or not is_nil(parent)) and
         Enum.all?(ids, &valid_id?/1) and
         Enum.uniq(ids) == ids and is_map(metadata) and Codec.valid?(metadata, max_bytes: 64_000) and
         (is_nil(parent) or valid_parent(parent) == :ok),
       do: :ok,
       else: {:error, :invalid_batch_plan}
  end

  defp valid_parent(parent) when is_map(parent) do
    if Codec.valid?(parent, max_bytes: @max_checkpoint_bytes),
      do: :ok,
      else: {:error, :checkpoint_not_portable_or_too_large}
  end

  defp valid_parent(_), do: {:error, :checkpoint_not_portable_or_too_large}

  defp retireable?(%{phase: :claimed}), do: true
  defp retireable?(%{phase: :children, packet: %{"join" => join}}), do: is_map(join)
  defp retireable?(_), do: false

  defp valid_key(key) when is_binary(key) and byte_size(key) in 1..256 do
    if String.valid?(key), do: :ok, else: {:error, :invalid_batch_key}
  end

  defp valid_key(_), do: {:error, :invalid_batch_key}

  defp valid_revision(revision) when is_integer(revision) and revision >= 1, do: :ok
  defp valid_revision(_), do: {:error, :invalid_approval_revision}

  defp valid_approval_child_id(child_id) do
    if valid_id?(child_id), do: :ok, else: {:error, :unknown_child}
  end

  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id)
  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp nonce?(value),
    do: is_binary(value) and byte_size(value) == 32 and String.match?(value, ~r/\A[0-9a-f]+\z/)

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
