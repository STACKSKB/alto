defmodule Alto.Subagents.Continuation do
  @moduledoc """
  A retained, single-use parent continuation in an `Alto.OperationLog`.

  The caller stores the pending parent frame before admitting children, then
  replaces it with the exact post-join frame before acknowledging their journal.
  Claiming that frame is a durable, single-use grant to continue parent work.
  An uncertain claim never grants permission to repeat downstream effects.
  """

  alias Alto.Persistence.Retained

  @enforce_keys [:ledger, :key, :generation]
  defstruct [:ledger, :key, :generation, deadline: :infinity]

  @kind "alto_subagent_parent_continuation"
  @initialize "initialize-parent-continuation"
  @retire "retire-parent-continuation"
  @max_packet_bytes 2_000_000
  @max_metadata_bytes 64_000
  @identity_keys ~w(key generation)
  @initial_keys ~w(kind version generation pending_digest metadata_digest)
  @checkpoint_keys ~w(kind version generation phase packet metadata)

  @doc "Open a new pending cell, or reconnect only if its immutable opening data matches."
  def open(ledger, key, pending_packet, metadata \\ %{}, opts \\ []) do
    with :ok <- valid_key(key),
         :ok <- valid_packet_input(pending_packet),
         :ok <- valid_metadata(metadata),
         {:ok, deadline} <- deadline_option(opts) do
      initial = %{
        "kind" => @kind,
        "version" => 1,
        "generation" => nonce(),
        "pending_digest" => digest(pending_packet),
        "metadata_digest" => digest(metadata)
      }

      safe(fn ->
        with :ok <- Retained.deadline_ok(deadline),
             {:ok, entry} <-
               Retained.ensure_intent(ledger, key, @kind, nil, initial, deadline),
             :ok <- valid_initial(entry),
             :ok <- same_opening(entry.recovery, initial),
             cell = %__MODULE__{
               ledger: ledger,
               key: key,
               generation: entry.recovery["generation"],
               deadline: deadline
             },
             :ok <- initialize(cell, entry, pending_packet, metadata),
             {:ok, _} <- read(cell) do
          {:ok, cell}
        end
      end)
    end
  end

  @doc "Portable key and generation binding for a saved parent run."
  def identity(%__MODULE__{key: key, generation: generation}),
    do: %{"key" => key, "generation" => generation}

  @doc "Reconnect only to an existing, checkpointed generation."
  def restore(ledger, identity, opts \\ []) do
    with :ok <- valid_identity(identity),
         {:ok, deadline} <- deadline_option(opts) do
      cell = %__MODULE__{
        ledger: ledger,
        key: identity["key"],
        generation: identity["generation"],
        deadline: deadline
      }

      with {:ok, _} <- read(cell), do: {:ok, cell}
    end
  end

  @doc "Read the exact retained frame, revision, and retirement state."
  def read(%__MODULE__{} = cell) do
    safe(fn ->
      with {:ok, entry} <- Retained.read(cell.ledger, cell.key, cell.deadline),
           :ok <- valid_initial(entry),
           true <- entry.recovery["generation"] == cell.generation,
           :ok <- valid_checkpoint_entry(entry),
           {:ok, state} <- lifecycle(entry) do
        {:ok, snapshot(entry, state)}
      else
        false -> {:error, :continuation_generation_mismatch}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Replace a pending frame with the exact post-join frame at a viewed revision."
  def ready(%__MODULE__{} = cell, expected_revision, ready_packet) do
    with :ok <- valid_revision(expected_revision),
         :ok <- valid_packet_input(ready_packet),
         {:ok, current} <- read(cell),
         :ok <- expected(current, expected_revision, :pending),
         replacement <-
           checkpoint(cell.generation, :ready, ready_packet, current.metadata) do
      replace(cell, expected_revision, replacement)
    end
  end

  @doc "Claim a ready frame once. The retained claimed state never grants a retry."
  def claim(%__MODULE__{} = cell, expected_revision) do
    with :ok <- valid_revision(expected_revision),
         {:ok, current} <- read(cell),
         :ok <- expected(current, expected_revision, :ready),
         replacement <-
           checkpoint(cell.generation, :claimed, current.packet, current.metadata) do
      replace(cell, expected_revision, replacement)
    end
  end

  @doc "Retire a claimed frame at its viewed revision. An interrupted retirement can be finished at its new revision."
  def retire(%__MODULE__{} = cell, expected_revision) do
    with :ok <- valid_revision(expected_revision) do
      safe(fn ->
        with {:ok, current} <- read(cell),
             :ok <- expected_retirement(current, expected_revision),
             :ok <- begin_retirement(cell, current),
             :ok <- finish_retirement(cell) do
          :ok
        end
      end)
    end
  end

  defp replace(cell, revision, replacement) do
    safe(fn ->
      with {:ok, entry} <-
             Retained.cas(cell.ledger, cell.key, revision, replacement, cell.deadline),
           :ok <- valid_initial(entry),
           true <- entry.recovery["generation"] == cell.generation,
           :ok <- valid_checkpoint_entry(entry),
           {:ok, state} <- lifecycle(entry) do
        {:ok, snapshot(entry, state)}
      else
        false -> {:error, :continuation_generation_mismatch}
        {:error, _} = error -> error
      end
    end)
  end

  defp expected(%{revision: revision}, expected_revision, _phase)
       when revision != expected_revision,
       do: {:error, :stale_revision}

  defp expected(%{phase: phase}, _revision, phase), do: :ok

  defp expected(%{phase: :claimed}, _revision, :ready),
    do: {:error, :continuation_already_claimed}

  defp expected(%{phase: :ready}, _revision, :pending), do: {:error, :continuation_already_ready}
  defp expected(_, _, _), do: {:error, :invalid_continuation_phase}

  defp expected_retirement(%{revision: revision}, expected_revision)
       when revision != expected_revision,
       do: {:error, :stale_revision}

  defp expected_retirement(%{phase: :claimed}, _revision), do: :ok
  defp expected_retirement(_, _revision), do: {:error, :invalid_continuation_phase}

  defp begin_retirement(cell, %{state: :active} = snapshot) do
    with {:ok, _} <-
           Retained.resume(
             cell.ledger,
             cell.key,
             snapshot.revision,
             %{"action" => @retire, "generation" => cell.generation},
             cell.deadline
           ),
         do: :ok
  end

  defp begin_retirement(_, %{state: state}) when state in [:retiring, :retired], do: :ok

  # Retirement only writes deterministic ledger records; no parent grant is reissued.
  defp finish_retirement(cell) do
    with {:ok, snapshot} <- read(cell) do
      if snapshot.state == :retired do
        :ok
      else
        case Retained.record_attempt(cell.ledger, cell.key, @retire, cell.deadline) do
          :ok ->
            case Retained.record_outcome(
                   cell.ledger,
                   cell.key,
                   @retire,
                   :completed,
                   %{"generation" => cell.generation, "claimed" => true},
                   cell.deadline
                 ) do
              :ok -> :ok
              {:error, :already_decided} -> retired_after_race(cell)
              error -> error
            end

          {:error, :already_decided} ->
            retired_after_race(cell)

          error ->
            error
        end
      end
    end
  end

  defp retired_after_race(cell) do
    case read(cell) do
      {:ok, %{state: :retired}} -> :ok
      {:ok, _} -> {:error, :continuation_not_retired}
      error -> error
    end
  end

  defp same_opening(recovery, opening) do
    if recovery["pending_digest"] == opening["pending_digest"] and
         recovery["metadata_digest"] == opening["metadata_digest"],
       do: :ok,
       else: {:error, :continuation_plan_conflict}
  end

  defp initialize(_cell, %{checkpoint: packet}, _pending, _metadata) when is_map(packet),
    do: :ok

  defp initialize(cell, %{status: {:intended}}, pending, metadata) do
    case Retained.record_attempt(cell.ledger, cell.key, @initialize, cell.deadline) do
      :ok ->
        with {:ok, entry} <- Retained.read(cell.ledger, cell.key, cell.deadline),
             do: initialize(cell, entry, pending, metadata)

      {:error, :checkpoint_active} ->
        :ok

      error ->
        error
    end
  end

  defp initialize(cell, %{status: {:dispatched, @initialize}}, pending, metadata) do
    packet = checkpoint(cell.generation, :pending, pending, metadata)

    case Retained.record_checkpoint(cell.ledger, cell.key, @initialize, packet, cell.deadline) do
      :ok -> :ok
      {:error, :checkpoint_active} -> :ok
      error -> error
    end
  end

  defp initialize(_, _, _, _), do: {:error, :invalid_continuation}

  defp checkpoint(generation, phase, packet, metadata) do
    %{
      "kind" => @kind,
      "version" => 1,
      "generation" => generation,
      "phase" => Atom.to_string(phase),
      "packet" => packet,
      "metadata" => metadata
    }
  end

  defp snapshot(entry, state) do
    %{
      revision: entry.revision,
      state: state,
      phase: String.to_existing_atom(entry.checkpoint["phase"]),
      packet: entry.checkpoint["packet"],
      metadata: entry.checkpoint["metadata"]
    }
  end

  defp valid_checkpoint_entry(%{checkpoint: packet, recovery: initial} = entry)
       when is_integer(entry.revision) and entry.revision >= 1 do
    if is_map(packet) and Enum.sort(Map.keys(packet)) == Enum.sort(@checkpoint_keys) and
         packet["kind"] == @kind and packet["version"] == 1 and
         packet["generation"] == initial["generation"] and
         packet["phase"] in ~w(pending ready claimed) and
         valid_packet_input(packet["packet"]) == :ok and
         valid_metadata(packet["metadata"]) == :ok and
         digest(packet["metadata"]) == initial["metadata_digest"] and
         (packet["phase"] != "pending" or
            digest(packet["packet"]) == initial["pending_digest"]),
       do: :ok,
       else: {:error, :invalid_continuation}
  end

  defp valid_checkpoint_entry(_), do: {:error, :invalid_continuation}

  defp lifecycle(%{status: {:checkpointed, _, @initialize}}), do: {:ok, :active}

  defp lifecycle(
         %{
           checkpoint_decision: %{"action" => @retire, "generation" => generation},
           recovery: %{"generation" => generation},
           checkpoint: %{"phase" => "claimed"}
         } = entry
       ) do
    case entry.status do
      {:intended} ->
        {:ok, :retiring}

      {:dispatched, @retire} ->
        {:ok, :retiring}

      {:decided, :completed, %{"generation" => ^generation, "claimed" => true}} ->
        {:ok, :retired}

      _ ->
        {:error, :invalid_continuation}
    end
  end

  defp lifecycle(_), do: {:error, :invalid_continuation}

  defp valid_initial(%{tool: @kind, recovery: initial}) when is_map(initial) do
    if Enum.sort(Map.keys(initial)) == Enum.sort(@initial_keys) and initial["kind"] == @kind and
         initial["version"] == 1 and nonce?(initial["generation"]) and
         digest?(initial["pending_digest"]) and digest?(initial["metadata_digest"]),
       do: :ok,
       else: {:error, :invalid_continuation}
  end

  defp valid_initial(_), do: {:error, :invalid_continuation}

  defp valid_identity(identity) when is_map(identity) do
    if Enum.sort(Map.keys(identity)) == Enum.sort(@identity_keys) and
         valid_key(identity["key"]) == :ok and nonce?(identity["generation"]),
       do: :ok,
       else: {:error, :invalid_continuation_identity}
  end

  defp valid_identity(_), do: {:error, :invalid_continuation_identity}

  defp valid_key(key) when is_binary(key) do
    if byte_size(key) in 1..256 and String.valid?(key),
      do: :ok,
      else: {:error, :invalid_continuation_key}
  end

  defp valid_key(_), do: {:error, :invalid_continuation_key}

  defp valid_revision(revision) when is_integer(revision) and revision >= 1, do: :ok
  defp valid_revision(_), do: {:error, :invalid_continuation_revision}

  defp valid_packet_input(packet) when is_map(packet) do
    if portable_json?(packet, @max_packet_bytes),
      do: :ok,
      else: {:error, :continuation_packet_not_portable_or_too_large}
  end

  defp valid_packet_input(_), do: {:error, :continuation_packet_not_portable_or_too_large}

  defp valid_metadata(metadata) when is_map(metadata) do
    journal = metadata["journal"]

    if portable_json?(metadata, @max_metadata_bytes) and
         valid_identity(journal) == :ok,
       do: :ok,
       else: {:error, :invalid_continuation_metadata}
  end

  defp valid_metadata(_), do: {:error, :invalid_continuation_metadata}

  defp deadline_option(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) in [[], [:deadline]] do
      deadline = Keyword.get(opts, :deadline, :infinity)

      case Retained.deadline_ok(deadline) do
        :ok -> {:ok, deadline}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_continuation_options}
    end
  end

  defp portable_json?(term, max_bytes) do
    if :erlang.external_size(term) <= max_bytes do
      json = JSON.encode!(term)
      byte_size(json) <= max_bytes and JSON.decode(json) == {:ok, term}
    else
      false
    end
  rescue
    _ -> false
  end

  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp nonce?(value),
    do:
      is_binary(value) and byte_size(value) == 32 and
        String.match?(value, ~r/\A[0-9a-f]{32}\z/)

  defp digest?(value),
    do:
      is_binary(value) and byte_size(value) == 64 and
        String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp digest(value),
    do: :crypto.hash(:sha256, JSON.encode!(value)) |> Base.encode16(case: :lower)

  defp safe(fun) do
    fun.()
  catch
    :exit, {:timeout, _reason} -> {:error, :run_timeout}
    :exit, reason -> {:error, {:parent_continuation_unavailable, reason}}
  end
end
