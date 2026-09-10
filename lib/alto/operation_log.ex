defmodule Alto.OperationLog do
  @moduledoc """
  A bounded operation ledger for demonstrated short-run flows.

  The ledger records the minimal facts a crashed-then-restarted consumer
  needs to avoid inventing outcomes: operation *intent* (what was decided
  to do, under which semantic identity), *attempts* (which dispatch tried,
  under which attempt identity), and *outcome evidence* (what the
  participant reported, in `Alto.Effect.Outcome` classes). One GenServer
  per ledger id, one append-only file-synced JSONL log under the state home
  (`operation_logs/<id>.jsonl`); a torn trailing write is discarded on
  replay, any other corruption fails the start loudly.

  Ordering is enforced, not advised: an attempt requires a prior intent,
  and an outcome requires a prior attempt. Intent is therefore always
  written before dispatch by construction.

  Relation between operation state and inbox completion (the recovery
  table; the consumer implements it):

    * `:no_intent` + live work → may record intent, then dispatch;
    * `{:intended}` + live work → may dispatch (new attempt). A released
      attempt (see `record_release/3`) returns the operation here: release
      is the only path back from dispatched without an outcome, so a
      re-dispatch after release is a counted retry, while a re-dispatch
      after an unreleased attempt is a forbidden blind replay;
    * `{:dispatched, attempt}` + live work → MUST reconcile with the
      authoritative participant or park as `:requires_operator` — never
      re-dispatch blindly and never ack;
    * `{:checkpointed, packet, attempt}` + live work → ack without execution;
      a revision-fenced host decision is required before a continuation;
    * `{:decided, class, _}` + live work → ack *without* re-running (the
      evidence stands; success is never invented from a transcript, it is
      read from the recorded outcome);
    * live work gone + no outcome → anomaly: something acked outside the
      consumer; operator review via `list_open/1`.

  What is stored — and what is not: intent keeps the semantic operation
  key, the tool name, and the inbox key. Attempt keeps the attempt id
  (consumers pass the queue `claim_id`, which already rotates per owner).
  Evidence is scrubbed of credential-shaped keys before persistence. Raw
  continuation and recovery packets are exact and are not scrubbed; their
  messages and tool values require private storage. Hosts exclude provider
  credentials and live capabilities from continuation packets.

  Bounds: indexed operations ≤ `max_ops` (default 10,000); only *decided*
  operations are evicted (oldest first), undecided work is never dropped —
  a full ledger of undecided work answers `{:error, :ledger_full}`
  (retryable) instead of forgetting it.
  """

  use GenServer

  alias Alto.Session, as: SessionStore
  alias Alto.DurableLog

  @version 1
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  @default_max_ops 10_000
  @max_key_bytes 256
  @default_max_identifier_bytes 256
  @default_max_evidence_bytes 64_000
  @default_max_recovery_bytes 64_000
  @default_max_record_bytes 128_000
  @default_max_log_bytes 64_000_000
  @default_max_attempts 32
  @scrub_pattern ~r/password|secret|token|api_key|apikey|credential|private_key/i

  @enforce_keys [
    :id,
    :dir,
    :path,
    :max_ops,
    :max_identifier_bytes,
    :max_evidence_bytes,
    :max_recovery_bytes,
    :max_record_bytes,
    :max_log_bytes,
    :max_attempts
  ]
  defstruct [
    :id,
    :dir,
    :path,
    :lock,
    :max_ops,
    :max_identifier_bytes,
    :max_evidence_bytes,
    :max_recovery_bytes,
    :max_record_bytes,
    :max_log_bytes,
    :max_attempts,
    ops: %{},
    order: []
  ]

  @type op_key :: String.t()
  @type status ::
          :no_intent
          | {:intended}
          | {:dispatched, String.t()}
          | {:checkpointed, map(), String.t()}
          | {:decided, Alto.Effect.Outcome.class(), map()}

  ## Client API

  @doc """
  Start a ledger. Options: `:id` (required, filesystem-safe), `:dir`
  (default `<state home>/alto/operation_logs`), `:name`, `:max_ops`,
  `:max_identifier_bytes`, `:max_evidence_bytes`, `:max_recovery_bytes`,
  `:max_record_bytes`, and `:max_attempts`.
  `:max_log_bytes` bounds the bytes read during replay (default 64 MiB).
  """
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    :ok = validate_id!(id)

    max_ops = Keyword.get(opts, :max_ops, @default_max_ops)

    max_identifier_bytes =
      Keyword.get(opts, :max_identifier_bytes, @default_max_identifier_bytes)

    max_evidence_bytes = Keyword.get(opts, :max_evidence_bytes, @default_max_evidence_bytes)
    max_recovery_bytes = Keyword.get(opts, :max_recovery_bytes, @default_max_recovery_bytes)
    max_record_bytes = Keyword.get(opts, :max_record_bytes, @default_max_record_bytes)
    max_log_bytes = Keyword.get(opts, :max_log_bytes, @default_max_log_bytes)
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)

    with :ok <- validate_max_ops(max_ops),
         :ok <- validate_positive_limit(:max_identifier_bytes, max_identifier_bytes),
         :ok <- validate_positive_limit(:max_evidence_bytes, max_evidence_bytes),
         :ok <- validate_positive_limit(:max_recovery_bytes, max_recovery_bytes),
         :ok <- validate_positive_limit(:max_record_bytes, max_record_bytes),
         :ok <- validate_positive_limit(:max_log_bytes, max_log_bytes),
         :ok <- validate_positive_limit(:max_attempts, max_attempts) do
      state = %__MODULE__{
        id: id,
        dir: Keyword.get(opts, :dir, dir(opts)),
        path: log_path(Keyword.get(opts, :dir, dir(opts)), id),
        max_ops: max_ops,
        max_identifier_bytes: max_identifier_bytes,
        max_evidence_bytes: max_evidence_bytes,
        max_recovery_bytes: max_recovery_bytes,
        max_record_bytes: max_record_bytes,
        max_log_bytes: max_log_bytes,
        max_attempts: max_attempts
      }

      case Alto.Storage.acquire(state.path <> ".lock",
             timeout: Keyword.get(opts, :lock_timeout, 5_000)
           ) do
        {:ok, lock} ->
          case load(state) do
            {:ok, state} ->
              case GenServer.start_link(__MODULE__, %{state | lock: lock},
                     name: Keyword.get(opts, :name, __MODULE__)
                   ) do
                {:ok, pid} = result ->
                  case Alto.Storage.connect(lock, pid) do
                    :ok ->
                      result

                    {:error, reason} ->
                      GenServer.stop(pid, {:lock_connect_failed, reason})
                      Alto.Storage.release(lock)
                      {:error, reason}
                  end

                {:error, _reason} = result ->
                  Alto.Storage.release(lock)
                  result
              end

            {:error, reason} ->
              Alto.Storage.release(lock)
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Storage directory, honouring an explicit override."
  @spec dir(keyword()) :: Path.t()
  def dir(opts \\ []) do
    case Keyword.get(opts, :dir) do
      nil -> Path.join([state_home(), "alto", "operation_logs"])
      path when is_binary(path) -> path
    end
  end

  @doc "Record intent to perform `op_key` with `tool` for `inbox_key`. Idempotent."
  @spec record_intent(GenServer.server(), op_key(), binary(), binary() | nil, map() | nil) ::
          :ok | {:error, term()}
  def record_intent(server \\ __MODULE__, op_key, tool, inbox_key, recovery \\ nil) do
    GenServer.call(server, {:intent, op_key, tool, inbox_key, recovery})
  end

  @doc "Record a dispatch attempt. Requires a prior intent and no live attempt."
  @spec record_attempt(GenServer.server(), op_key(), String.t()) :: :ok | {:error, term()}
  def record_attempt(server \\ __MODULE__, op_key, attempt_id) do
    GenServer.call(server, {:attempt, op_key, attempt_id})
  end

  @doc """
  Record that an attempt was cleanly released back to live work (the
  consumer's queue release succeeded). The next dispatch under the same
  identity is a counted retry — this is the only path from dispatched back
  to `{:intended}` without an outcome. Requires the attempt to exist.
  """
  @spec record_release(GenServer.server(), op_key(), String.t()) :: :ok | {:error, term()}
  def record_release(server \\ __MODULE__, op_key, attempt_id) do
    GenServer.call(server, {:release, op_key, attempt_id})
  end

  @doc "Record outcome evidence for the current attempt. Historical attempts are fenced."
  @spec record_outcome(
          GenServer.server(),
          op_key(),
          String.t(),
          Alto.Effect.Outcome.class(),
          map()
        ) ::
          :ok | {:error, term()}
  def record_outcome(server \\ __MODULE__, op_key, attempt_id, class, evidence \\ %{}) do
    GenServer.call(server, {:outcome, op_key, attempt_id, class, evidence})
  end

  @doc "Persist a nonterminal continuation checkpoint for the current attempt."
  def record_checkpoint(server \\ __MODULE__, op_key, attempt_id, checkpoint) do
    GenServer.call(server, {:checkpoint, op_key, attempt_id, checkpoint})
  end

  @doc "Update an active checkpoint in place, fenced by its current revision."
  def update_checkpoint(server \\ __MODULE__, op_key, expected_revision, checkpoint) do
    GenServer.call(server, {:checkpoint_update, op_key, expected_revision, checkpoint})
  end

  @doc "Record a host decision to resume a checkpoint, fenced by revision."
  def resume_checkpoint(server \\ __MODULE__, op_key, expected_revision, decision) do
    GenServer.call(server, {:resume_checkpoint, op_key, expected_revision, decision})
  end

  @doc "Recovery status for `op_key` (see the module recovery table)."
  @spec status(GenServer.server(), op_key()) :: status()
  def status(server \\ __MODULE__, op_key) do
    GenServer.call(server, {:status, op_key})
  end

  @doc "Attempt count for `op_key` (0 when unknown)."
  @spec attempts(GenServer.server(), op_key()) :: non_neg_integer()
  def attempts(server \\ __MODULE__, op_key) do
    GenServer.call(server, {:attempts, op_key})
  end

  @doc "Atomically reject an intended operation before dispatch, fenced by revision."
  @spec reject_intended(GenServer.server(), op_key(), pos_integer(), map()) ::
          :ok | {:error, term()}
  def reject_intended(server \\ __MODULE__, op_key, expected_revision, evidence \\ %{}) do
    GenServer.call(server, {:reject_intended, op_key, expected_revision, evidence})
  end

  @doc "All retained operation keys, oldest first, including released/intended entries."
  @spec keys(GenServer.server()) :: [op_key()]
  def keys(server \\ __MODULE__) do
    GenServer.call(server, :keys)
  end

  @doc "Operation keys with no recorded outcome, oldest first (operator review)."
  @spec list_open(GenServer.server()) :: [op_key()]
  def list_open(server \\ __MODULE__) do
    GenServer.call(server, :list_open)
  end

  @doc "Operation keys parked for an operator, oldest first."
  @spec list_parked(GenServer.server()) :: [op_key()]
  def list_parked(server \\ __MODULE__) do
    GenServer.call(server, :list_parked)
  end

  @doc """
  Decided operations with their outcome class, oldest first (operator
  inspection). Read-only; bounded by `max_ops`. Includes parked
  (`:requires_operator`) entries — callers filter by class.
  """
  @spec list_decided(GenServer.server()) :: [{op_key(), Alto.Effect.Outcome.class()}]
  def list_decided(server \\ __MODULE__) do
    GenServer.call(server, :list_decided)
  end

  @doc "Return the bounded recovery envelope and active version for one operation."
  @spec recovery(GenServer.server(), op_key()) :: {:ok, map()} | {:error, :not_found}
  def recovery(server \\ __MODULE__, op_key) do
    GenServer.call(server, {:recovery, op_key})
  end

  @doc """
  Apply an audited operator reconciliation if `expected_revision` is still
  current. `:confirmed_committed` closes without dispatch,
  `:confirmed_failed` records a known terminal failure, and
  `:retry_permitted` returns the operation to intended state so its retained
  recovery envelope can be restored to a queue explicitly.
  """
  @spec reconcile(GenServer.server(), op_key(), pos_integer(), atom(), map()) ::
          {:ok, map()} | {:error, term()}
  def reconcile(server \\ __MODULE__, op_key, expected_revision, resolution, evidence \\ %{}) do
    GenServer.call(server, {:reconcile, op_key, expected_revision, resolution, evidence})
  end

  @doc "Remove credential-shaped entries from an evidence map before persistence."
  @spec scrub(map()) :: map()
  def scrub(evidence) when is_map(evidence) do
    Map.new(evidence, fn {key, value} ->
      name = if is_atom(key), do: Atom.to_string(key), else: key

      if is_binary(name) and name =~ @scrub_pattern do
        {key, "[redacted]"}
      else
        {key, value}
      end
    end)
  end

  ## Server implementation

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  @impl true
  def handle_call({:intent, op_key, tool, inbox_key, recovery}, _from, state) do
    with :ok <- validate_key(op_key),
         :ok <- validate_tool(tool, state),
         :ok <- validate_inbox(inbox_key, state),
         :ok <- validate_recovery(recovery, state) do
      case Map.fetch(state.ops, op_key) do
        {:ok, entry} ->
          if same_intent?(entry, tool, inbox_key, recovery) do
            {:reply, :ok, state}
          else
            {:reply, {:error, :intent_conflict}, state}
          end

        :error ->
          with {:ok, state} <- ensure_room(state) do
            log = %{
              "v" => @version,
              "t" => "intent",
              "op" => op_key,
              "tool" => tool,
              "inbox" => inbox_key,
              "recovery" => encode_recovery(recovery),
              "at_ms" => System.system_time(:millisecond)
            }

            case append(state, log) do
              :ok ->
                entry = %{
                  tool: tool,
                  inbox: inbox_key,
                  recovery: recovery,
                  attempts: [],
                  released: [],
                  outcome: nil,
                  checkpoint: nil,
                  checkpoint_decision: nil,
                  checkpoint_active: false,
                  checkpointed_attempts: [],
                  checkpoint_grant_revision: nil,
                  revision: 1
                }

                {:reply, :ok,
                 %{state | ops: Map.put(state.ops, op_key, entry), order: state.order ++ [op_key]}}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
          else
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:attempt, op_key, attempt_id}, _from, state) do
    with :ok <- validate_key(op_key),
         :ok <- validate_attempt(attempt_id, state),
         {:ok, entry} <- fetch_op(state, op_key) do
      cond do
        entry.outcome != nil ->
          {:reply, {:error, :already_decided}, state}

        entry.checkpoint_active ->
          {:reply, {:error, :checkpoint_active}, state}

        attempt_id in entry.attempts ->
          if attempt_id == current_attempt(entry) and active_attempt?(entry) do
            {:reply, :ok, state}
          else
            {:reply, {:error, :stale_attempt}, state}
          end

        active_attempt?(entry) ->
          {:reply, {:error, :attempt_in_flight}, state}

        length(entry.attempts) >= state.max_attempts ->
          {:reply, {:error, :attempt_history_full}, state}

        true ->
          log = %{
            "v" => @version,
            "t" => "attempt",
            "op" => op_key,
            "attempt" => attempt_id,
            "at_ms" => System.system_time(:millisecond)
          }

          case append(state, log) do
            :ok ->
              entry = %{
                entry
                | attempts: entry.attempts ++ [attempt_id],
                  checkpoint_active: false,
                  revision: entry.revision + 1
              }

              {:reply, :ok, %{state | ops: Map.put(state.ops, op_key, entry)}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:outcome, op_key, attempt_id, class, evidence}, _from, state) do
    with :ok <- validate_key(op_key),
         :ok <- validate_attempt(attempt_id, state),
         :ok <- validate_class(class),
         :ok <- validate_evidence(evidence, state),
         {:ok, entry} <- fetch_op(state, op_key) do
      cond do
        entry.attempts == [] ->
          {:reply, {:error, :no_attempt}, state}

        entry.outcome != nil and not outcome_can_be_escalated?(entry.outcome, class) ->
          {:reply, {:error, :already_decided}, state}

        entry.checkpoint_active ->
          {:reply, {:error, :checkpoint_active}, state}

        attempt_id != current_attempt(entry) or attempt_id in entry.released ->
          {:reply, {:error, :stale_attempt}, state}

        true ->
          log = %{
            "v" => @version,
            "t" => "outcome",
            "op" => op_key,
            "attempt" => attempt_id,
            "class" => Atom.to_string(class),
            "evidence" => scrub(evidence),
            "at_ms" => System.system_time(:millisecond)
          }

          case append(state, log) do
            :ok ->
              entry = %{
                entry
                | outcome: {class, scrub(evidence), attempt_id},
                  revision: entry.revision + 1
              }

              state = %{state | ops: Map.put(state.ops, op_key, entry)}
              {:reply, :ok, evict_decided(state)}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:checkpoint, op_key, attempt_id, checkpoint}, _from, state) do
    with :ok <- validate_key(op_key),
         :ok <- validate_attempt(attempt_id, state),
         :ok <- validate_checkpoint(checkpoint, state),
         {:ok, entry} <- fetch_op(state, op_key) do
      cond do
        entry.outcome != nil ->
          {:reply, {:error, :already_decided}, state}

        entry.checkpoint_active ->
          {:reply, {:error, :checkpoint_active}, state}

        attempt_id != current_attempt(entry) or attempt_id in entry.released ->
          {:reply, {:error, :stale_attempt}, state}

        true ->
          log = %{
            "v" => @version,
            "t" => "checkpoint",
            "op" => op_key,
            "expected_revision" => entry.revision,
            "attempt" => attempt_id,
            "checkpoint" => checkpoint,
            "at_ms" => System.system_time(:millisecond)
          }

          case append(state, log) do
            :ok ->
              entry = %{
                entry
                | checkpoint: checkpoint,
                  checkpoint_active: true,
                  checkpoint_decision: nil,
                  checkpointed_attempts: Enum.uniq(entry.checkpointed_attempts ++ [attempt_id]),
                  checkpoint_grant_revision: nil,
                  revision: entry.revision + 1
              }

              {:reply, :ok, %{state | ops: Map.put(state.ops, op_key, entry)}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resume_checkpoint, op_key, expected_revision, decision}, _from, state) do
    with :ok <- validate_key(op_key),
         :ok <- validate_revision(expected_revision),
         :ok <- validate_checkpoint_decision(decision, state),
         {:ok, entry} <- fetch_op(state, op_key),
         :ok <- expect_revision(entry, expected_revision) do
      cond do
        not entry.checkpoint_active ->
          {:reply, {:error, :not_checkpointed}, state}

        true ->
          log = %{
            "v" => @version,
            "t" => "checkpoint_resume",
            "op" => op_key,
            "expected_revision" => expected_revision,
            "decision" => decision,
            "at_ms" => System.system_time(:millisecond)
          }

          case append(state, log) do
            :ok ->
              entry = %{
                entry
                | checkpoint_decision: decision,
                  checkpoint_active: false,
                  checkpoint_grant_revision: entry.revision + 1,
                  released: Enum.uniq(entry.released ++ [current_attempt(entry)]),
                  revision: entry.revision + 1
              }

              state = %{state | ops: Map.put(state.ops, op_key, entry)}
              {:reply, {:ok, recovery_view(op_key, entry)}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:checkpoint_update, op_key, expected_revision, checkpoint}, _from, state) do
    with :ok <- validate_key(op_key),
         :ok <- validate_revision(expected_revision),
         :ok <- validate_checkpoint(checkpoint, state),
         {:ok, entry} <- fetch_op(state, op_key),
         :ok <- expect_revision(entry, expected_revision) do
      cond do
        entry.outcome != nil ->
          {:reply, {:error, :already_decided}, state}

        not entry.checkpoint_active ->
          {:reply, {:error, :not_checkpointed}, state}

        true ->
          log = %{
            "v" => @version,
            "t" => "checkpoint_update",
            "op" => op_key,
            "expected_revision" => expected_revision,
            "checkpoint" => checkpoint,
            "at_ms" => System.system_time(:millisecond)
          }

          case append(state, log) do
            :ok ->
              entry = %{entry | checkpoint: checkpoint, revision: entry.revision + 1}
              state = %{state | ops: Map.put(state.ops, op_key, entry)}
              {:reply, {:ok, recovery_view(op_key, entry)}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:status, op_key}, _from, state) do
    {:reply, read_status(state, op_key), state}
  end

  def handle_call({:attempts, op_key}, _from, state) do
    case Map.fetch(state.ops, op_key) do
      {:ok, entry} -> {:reply, length(entry.attempts), state}
      :error -> {:reply, 0, state}
    end
  end

  def handle_call({:reject_intended, op_key, expected_revision, evidence}, _from, state) do
    with :ok <- validate_key(op_key),
         :ok <- validate_revision(expected_revision),
         :ok <- validate_evidence(evidence, state),
         {:ok, entry} <- fetch_op(state, op_key),
         :ok <- expect_revision(entry, expected_revision) do
      cond do
        entry.outcome != nil ->
          {:reply, {:error, :already_decided}, state}

        active_attempt?(entry) ->
          {:reply, {:error, :attempt_in_flight}, state}

        true ->
          attempt = rejection_attempt(op_key)
          scrubbed = scrub(evidence)

          log = %{
            "v" => @version,
            "t" => "reject",
            "op" => op_key,
            "expected_revision" => expected_revision,
            "attempt" => attempt,
            "evidence" => scrubbed,
            "at_ms" => System.system_time(:millisecond)
          }

          case apply_rejection(state, op_key, log) do
            {:ok, next_state} ->
              case append(state, log) do
                :ok -> {:reply, :ok, evict_decided(next_state)}
                {:error, reason} -> {:reply, {:error, reason}, state}
              end

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:keys, _from, state) do
    {:reply, state.order, state}
  end

  def handle_call(:list_open, _from, state) do
    open =
      state.order
      |> Enum.filter(fn key ->
        case Map.fetch!(state.ops, key) do
          # Healthy retry-in-flight (released, awaiting re-dispatch) is not
          # operator work; everything else without an outcome is.
          %{outcome: nil, attempts: []} ->
            true

          %{outcome: nil, attempts: attempts, released: released} ->
            List.last(attempts) not in released

          _ ->
            false
        end
      end)

    {:reply, open, state}
  end

  def handle_call(:list_parked, _from, state) do
    parked =
      state.order
      |> Enum.filter(fn key ->
        match?(%{outcome: {:requires_operator, _, _}}, Map.fetch!(state.ops, key))
      end)

    {:reply, parked, state}
  end

  def handle_call(:list_decided, _from, state) do
    decided =
      state.order
      |> Enum.flat_map(fn key ->
        case Map.fetch!(state.ops, key) do
          %{outcome: {class, _evidence, _attempt}} -> [{key, class}]
          _other -> []
        end
      end)

    {:reply, decided, state}
  end

  def handle_call({:recovery, op_key}, _from, state) do
    case Map.fetch(state.ops, op_key) do
      {:ok, entry} -> {:reply, {:ok, recovery_view(op_key, entry)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(
        {:reconcile, op_key, expected_revision, resolution, evidence},
        _from,
        state
      ) do
    with :ok <- validate_key(op_key),
         :ok <- validate_revision(expected_revision),
         :ok <- validate_resolution(resolution),
         :ok <- validate_evidence(evidence, state),
         {:ok, entry} <- fetch_op(state, op_key),
         :ok <- expect_revision(entry, expected_revision),
         :ok <- ensure_reconcilable(entry),
         :ok <- ensure_retry_recoverable(entry, resolution) do
      scrubbed = scrub(evidence)

      log = %{
        "v" => @version,
        "t" => "reconcile",
        "op" => op_key,
        "expected_revision" => expected_revision,
        "resolution" => Atom.to_string(resolution),
        "evidence" => scrubbed,
        "at_ms" => System.system_time(:millisecond)
      }

      case append(state, log) do
        :ok ->
          entry = apply_reconciliation(entry, resolution, scrubbed)
          state = %{state | ops: Map.put(state.ops, op_key, entry)}
          {:reply, {:ok, recovery_view(op_key, entry)}, evict_decided(state)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, op_key, attempt_id}, _from, state) do
    with :ok <- validate_key(op_key),
         :ok <- validate_attempt(attempt_id, state),
         {:ok, entry} <- fetch_op(state, op_key) do
      cond do
        entry.outcome != nil ->
          {:reply, {:error, :already_decided}, state}

        entry.attempts == [] ->
          {:reply, {:error, :no_attempt}, state}

        attempt_id not in entry.attempts ->
          {:reply, {:error, :no_attempt}, state}

        attempt_id != current_attempt(entry) ->
          {:reply, {:error, :stale_attempt}, state}

        attempt_id in entry.released ->
          {:reply, :ok, state}

        entry.checkpoint_active ->
          {:reply, {:error, :checkpoint_active}, state}

        true ->
          log = %{
            "v" => @version,
            "t" => "release",
            "op" => op_key,
            "attempt" => attempt_id,
            "at_ms" => System.system_time(:millisecond)
          }

          case append(state, log) do
            :ok ->
              entry = %{
                entry
                | released: entry.released ++ [attempt_id],
                  revision: entry.revision + 1
              }

              {:reply, :ok, %{state | ops: Map.put(state.ops, op_key, entry)}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  ## Internals

  defp read_status(state, op_key) do
    case Map.fetch(state.ops, op_key) do
      :error -> :no_intent
      {:ok, entry} -> entry_status(entry)
    end
  end

  defp entry_status(%{attempts: [], outcome: nil}), do: {:intended}

  defp entry_status(%{checkpoint_active: true, checkpoint: checkpoint, attempts: attempts}),
    do: {:checkpointed, checkpoint, List.last(attempts)}

  defp entry_status(%{attempts: attempts, released: released, outcome: nil}) do
    if List.last(attempts) in released,
      do: {:intended},
      else: {:dispatched, List.last(attempts)}
  end

  defp entry_status(%{outcome: {class, evidence, _attempt}}), do: {:decided, class, evidence}

  defp fetch_op(state, op_key) do
    case Map.fetch(state.ops, op_key) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :no_intent}
    end
  end

  # Only terminal operations may leave the index; unknown and parked work are
  # still recovery obligations and are never forgotten while memory is bounded.
  defp evict_decided(state) do
    if map_size(state.ops) <= state.max_ops do
      state
    else
      victim =
        Enum.find(state.order, fn key ->
          evictable?(Map.fetch!(state.ops, key))
        end)

      case victim do
        nil ->
          state

        key ->
          %{state | ops: Map.delete(state.ops, key), order: List.delete(state.order, key)}
      end
    end
  end

  defp ensure_room(state) do
    cond do
      map_size(state.ops) < state.max_ops ->
        {:ok, state}

      true ->
        case Enum.find(state.order, &evictable?(Map.fetch!(state.ops, &1))) do
          nil ->
            {:error, :ledger_full}

          key ->
            {:ok,
             %{state | ops: Map.delete(state.ops, key), order: List.delete(state.order, key)}}
        end
    end
  end

  defp active_attempt?(%{outcome: nil, attempts: attempts, released: released}) do
    attempts != [] and List.last(attempts) not in released
  end

  defp active_attempt?(_entry), do: false

  defp current_attempt(%{attempts: attempts}), do: List.last(attempts)

  defp same_intent?(entry, tool, inbox, recovery) do
    entry.tool == tool and entry.inbox == inbox and entry.recovery == recovery
  end

  defp recovery_view(op_key, entry) do
    %{
      operation_key: op_key,
      status: entry_status(entry),
      revision: entry.revision,
      tool: entry.tool,
      inbox_key: entry.inbox,
      recovery: entry.recovery,
      current_attempt: current_attempt_or_nil(entry),
      outcome: entry.outcome,
      checkpoint: entry.checkpoint,
      checkpoint_decision: entry.checkpoint_decision,
      checkpoint_grant_revision: entry.checkpoint_grant_revision,
      checkpointed_attempts: entry.checkpointed_attempts
    }
  end

  defp current_attempt_or_nil(%{attempts: []}), do: nil
  defp current_attempt_or_nil(entry), do: current_attempt(entry)

  defp expect_revision(%{revision: revision}, revision), do: :ok
  defp expect_revision(_entry, _expected), do: {:error, :stale_revision}

  defp ensure_reconcilable(%{checkpoint_active: true}), do: {:error, :checkpoint_active}
  defp ensure_reconcilable(%{outcome: nil, attempts: [_ | _]}), do: :ok

  defp ensure_reconcilable(%{outcome: {class, _evidence, _attempt}})
       when class in [:unknown, :requires_operator],
       do: :ok

  defp ensure_reconcilable(_entry), do: {:error, :not_reconcilable}

  defp ensure_retry_recoverable(%{recovery: recovery}, :retry_permitted) when is_map(recovery),
    do: :ok

  defp ensure_retry_recoverable(_entry, :retry_permitted), do: {:error, :recovery_unavailable}
  defp ensure_retry_recoverable(_entry, _resolution), do: :ok

  defp apply_reconciliation(entry, :retry_permitted, _evidence) do
    released =
      case current_attempt_or_nil(entry) do
        nil -> entry.released
        attempt -> Enum.uniq(entry.released ++ [attempt])
      end

    %{entry | released: released, outcome: nil, revision: entry.revision + 1}
  end

  defp apply_reconciliation(entry, resolution, evidence) do
    class = if resolution == :confirmed_committed, do: :completed, else: :failed_known
    attempt = current_attempt_or_nil(entry) || "operator"
    audit = %{operator_resolution: resolution, evidence: evidence}
    %{entry | outcome: {class, audit, attempt}, revision: entry.revision + 1}
  end

  defp outcome_can_be_escalated?({:unknown, _evidence, _attempt}, :requires_operator), do: true
  defp outcome_can_be_escalated?(_outcome, _class), do: false

  defp evictable?(%{outcome: {class, _evidence, _attempt}})
       when class in [:completed, :failed_known, :rejected_before_dispatch],
       do: true

  defp evictable?(_entry), do: false

  defp validate_key(key) when is_binary(key) do
    if byte_size(key) in 1..@max_key_bytes, do: :ok, else: {:error, {:invalid_op_key, key}}
  end

  defp validate_key(key), do: {:error, {:invalid_op_key, key}}

  defp validate_tool(tool, state) when is_binary(tool) and tool != "" do
    if byte_size(tool) <= state.max_identifier_bytes,
      do: :ok,
      else: {:error, {:identifier_too_large, :tool, state.max_identifier_bytes}}
  end

  defp validate_tool(tool, _state), do: {:error, {:invalid_tool, tool}}

  defp validate_inbox(nil, _state), do: :ok

  defp validate_inbox(key, state) when is_binary(key) do
    with :ok <- validate_key(key) do
      if byte_size(key) <= state.max_identifier_bytes,
        do: :ok,
        else: {:error, {:identifier_too_large, :inbox, state.max_identifier_bytes}}
    end
  end

  defp validate_inbox(key, _state), do: {:error, {:invalid_op_key, key}}

  defp validate_attempt(id, state) when is_binary(id) and id != "" do
    if byte_size(id) <= state.max_identifier_bytes,
      do: :ok,
      else: {:error, {:identifier_too_large, :attempt, state.max_identifier_bytes}}
  end

  defp validate_attempt(id, _state), do: {:error, {:invalid_attempt, id}}

  defp validate_revision(revision) when is_integer(revision) and revision >= 1, do: :ok
  defp validate_revision(revision), do: {:error, {:invalid_revision, revision}}

  defp validate_resolution(resolution)
       when resolution in [:confirmed_committed, :confirmed_failed, :retry_permitted],
       do: :ok

  defp validate_resolution(resolution), do: {:error, {:invalid_resolution, resolution}}

  defp validate_class(class)
       when class in [
              :completed,
              :rejected_before_dispatch,
              :failed_known,
              :unknown,
              :requires_operator
            ],
       do: :ok

  defp validate_class(class), do: {:error, {:invalid_outcome_class, class}}

  defp validate_evidence(evidence, state) when is_map(evidence) do
    if :erlang.external_size(scrub(evidence)) <= state.max_evidence_bytes,
      do: :ok,
      else: {:error, {:evidence_too_large, state.max_evidence_bytes}}
  end

  defp validate_evidence(evidence, _state), do: {:error, {:invalid_evidence, evidence}}

  defp validate_recovery(nil, _state), do: :ok

  defp validate_recovery(recovery, state) when is_map(recovery) do
    if :erlang.external_size(recovery) <= state.max_recovery_bytes,
      do: :ok,
      else: {:error, {:recovery_too_large, state.max_recovery_bytes}}
  end

  defp validate_recovery(recovery, _state), do: {:error, {:invalid_recovery, recovery}}

  defp validate_checkpoint(value, state) when is_map(value) do
    if :erlang.external_size(value) <= state.max_recovery_bytes do
      try do
        json = JSON.encode!(value)

        case JSON.decode(json) do
          {:ok, ^value} -> :ok
          _ -> {:error, :invalid_checkpoint}
        end
      rescue
        _ -> {:error, :invalid_checkpoint}
      end
    else
      {:error, :invalid_checkpoint}
    end
  end

  defp validate_checkpoint(_value, _state), do: {:error, :invalid_checkpoint}
  defp validate_checkpoint_decision(value, state), do: validate_checkpoint(value, state)

  defp encode_recovery(nil), do: nil
  defp encode_recovery(recovery), do: SessionStore.encode_term(recovery)

  defp decode_recovery(nil), do: {:ok, nil}
  defp decode_recovery(%{"$term" => _encoded} = recovery), do: SessionStore.decode_term(recovery)
  defp decode_recovery(recovery) when is_map(recovery), do: {:ok, recovery}
  defp decode_recovery(recovery) when is_binary(recovery), do: SessionStore.decode_term(recovery)
  defp decode_recovery(_recovery), do: {:error, :bad_recovery}

  defp validate_max_ops(n) when is_integer(n) and n >= 0, do: :ok
  defp validate_max_ops(n), do: {:error, {:invalid_max_ops, n}}

  defp validate_positive_limit(_name, n) when is_integer(n) and n >= 1, do: :ok
  defp validate_positive_limit(name, n), do: {:error, {:invalid_limit, name, n}}

  defp validate_id!(id) do
    if is_binary(id) and Regex.match?(@id_pattern, id) do
      :ok
    else
      raise ArgumentError, "invalid operation log id: #{inspect(id)}"
    end
  end

  ## Storage (append-only, file-synced JSONL with atomic tail repair — same
  ## contract as Alto.Queue; broader device guarantees are deployment-specific)

  defp load(state) do
    with :ok <- Alto.Storage.ensure_private_dir(state.dir, owned: true),
         :ok <- Alto.Storage.ensure_private_file(state.path),
         :ok <- DurableLog.ensure(state.path),
         {:ok, state} <- replay(state) do
      {:ok, state}
    end
  end

  defp replay(state) do
    case bounded_read(state.path, state.max_log_bytes) do
      {:ok, ""} ->
        {:ok, state}

      {:ok, contents} ->
        replay_contents(state, contents)

      {:error, {:too_large, size, max}} ->
        {:error, {:ledger_log_too_large, size, max}}

      {:error, :enoent} ->
        {:ok, state}

      {:error, reason} ->
        {:error, {:ledger_read_failed, reason}}
    end
  end

  defp bounded_read(path, max) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result =
          case IO.binread(io, max + 1) do
            {:error, reason} -> {:error, reason}
            :eof -> {:ok, <<>>}
            content when byte_size(content) > max -> {:error, {:too_large, max + 1, max}}
            content -> {:ok, content}
          end

        File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_contents(state, contents) do
    {lines, torn?} = split_log(contents)

    with {:ok, state} <- fold_lines(state, lines),
         {:ok, state} <- trim_to_bound(state) do
      if torn? do
        case DurableLog.replace(state.path, join_lines(lines)) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, {:ledger_read_failed, reason}}
        end
      else
        {:ok, state}
      end
    end
  end

  # Restart resurrects evicted decided entries from the audit log; trim back
  # to the bound here so memory stays bounded across restarts too.
  defp trim_to_bound(state) do
    if map_size(state.ops) <= state.max_ops do
      {:ok, state}
    else
      case Enum.find(state.order, &evictable?(Map.fetch!(state.ops, &1))) do
        nil ->
          {:error, {:ledger_capacity_exceeded, map_size(state.ops), state.max_ops}}

        key ->
          trim_to_bound(%{
            state
            | ops: Map.delete(state.ops, key),
              order: List.delete(state.order, key)
          })
      end
    end
  end

  defp split_log(contents) do
    if contents == "" do
      {[], false}
    else
      split_log_nonempty(contents)
    end
  end

  defp split_log_nonempty(contents) do
    if :binary.last(contents) == ?\n do
      {String.split(contents, "\n", trim: true), false}
    else
      parts = String.split(contents, "\n")
      {complete, [tail]} = Enum.split(parts, -1)
      complete = Enum.reject(complete, &(&1 == ""))

      case JSON.decode(tail) do
        # A valid final record without a newline is committed, but normalize
        # it before the next append so two JSON values cannot concatenate.
        {:ok, _} -> {complete ++ [tail], true}
        {:error, _} -> {complete, true}
      end
    end
  end

  defp join_lines([]), do: ""
  defp join_lines(lines), do: Enum.join(lines, "\n") <> "\n"

  defp fold_lines(state, lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, state}, fn {line, number}, {:ok, state} ->
      case apply_logged(state, line, number) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_logged(state, line, number) do
    with :ok <- validate_record_bytes(line, state) do
      case JSON.decode(line) do
        {:ok, %{"v" => @version, "t" => type, "op" => op} = entry}
        when is_binary(type) and is_binary(op) ->
          with :ok <- validate_key(op), do: log_apply(state, type, op, entry)

        _other ->
          {:error, {:ledger_corrupt, state.id, number}}
      end
    end
  end

  defp log_apply(state, "intent", op, entry) do
    if Map.has_key?(state.ops, op) do
      {:ok, state}
    else
      with {:ok, recovery} <- decode_recovery(entry["recovery"]),
           :ok <- validate_tool(entry["tool"], state),
           :ok <- validate_inbox(entry["inbox"], state),
           :ok <- validate_recovery(recovery, state) do
        record = %{
          tool: entry["tool"],
          inbox: entry["inbox"],
          recovery: recovery,
          attempts: [],
          released: [],
          outcome: nil,
          checkpoint: nil,
          checkpoint_decision: nil,
          checkpoint_active: false,
          checkpointed_attempts: [],
          checkpoint_grant_revision: nil,
          revision: 1
        }

        {:ok, %{state | ops: Map.put(state.ops, op, record), order: state.order ++ [op]}}
      end
    end
  end

  defp log_apply(state, "attempt", op, entry) do
    with :ok <- validate_attempt(entry["attempt"], state) do
      case Map.fetch(state.ops, op) do
        {:ok, record} ->
          attempt = entry["attempt"]

          cond do
            record.outcome != nil ->
              migration_required(state, op, {:attempt_after_outcome, attempt})

            record.checkpoint_active ->
              migration_required(state, op, :attempt_during_checkpoint)

            attempt in record.attempts ->
              if attempt == current_attempt(record) and active_attempt?(record) do
                {:ok, state}
              else
                migration_required(state, op, {:stale_attempt, attempt})
              end

            active_attempt?(record) ->
              migration_required(state, op, {:overlapping_attempt, attempt})

            length(record.attempts) >= state.max_attempts ->
              {:error, {:attempt_history_exceeded, op, state.max_attempts}}

            true ->
              record = %{
                record
                | attempts: record.attempts ++ [attempt],
                  revision: record.revision + 1
              }

              {:ok, %{state | ops: Map.put(state.ops, op, record)}}
          end

        :error ->
          {:error, :orphan_attempt}
      end
    end
  end

  defp log_apply(state, "release", op, entry) do
    with :ok <- validate_attempt(entry["attempt"], state) do
      case Map.fetch(state.ops, op) do
        {:ok, record} ->
          attempt = entry["attempt"]

          cond do
            attempt not in record.attempts ->
              {:error, :orphan_release}

            record.outcome != nil ->
              migration_required(state, op, {:release_after_outcome, attempt})

            record.checkpoint_active ->
              migration_required(state, op, :release_during_checkpoint)

            attempt != current_attempt(record) ->
              migration_required(state, op, {:stale_release, attempt})

            attempt in record.released ->
              {:ok, state}

            true ->
              record = %{
                record
                | released: record.released ++ [attempt],
                  revision: record.revision + 1
              }

              {:ok, %{state | ops: Map.put(state.ops, op, record)}}
          end

        :error ->
          {:error, :orphan_release}
      end
    end
  end

  defp log_apply(state, "outcome", op, entry) do
    with :ok <- validate_attempt(entry["attempt"], state),
         :ok <- validate_evidence(entry["evidence"], state) do
      case Map.fetch(state.ops, op) do
        {:ok, record} ->
          with {:ok, class} <- outcome_class(entry["class"]) do
            attempt = entry["attempt"]

            cond do
              record.attempts == [] ->
                {:error, :orphan_outcome}

              record.checkpoint_active ->
                migration_required(state, op, :outcome_during_checkpoint)

              attempt != current_attempt(record) or attempt in record.released ->
                migration_required(state, op, {:stale_outcome, attempt})

              record.outcome != nil and
                  not outcome_can_be_escalated?(record.outcome, class) ->
                migration_required(state, op, {:outcome_after_decision, attempt})

              true ->
                outcome = {class, entry["evidence"], attempt}
                record = %{record | outcome: outcome, revision: record.revision + 1}
                {:ok, %{state | ops: Map.put(state.ops, op, record)}}
            end
          end

        :error ->
          {:error, :orphan_outcome}
      end
    end
  end

  defp log_apply(state, "reject", op, entry) do
    case apply_rejection(state, op, entry) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> migration_required(state, op, {:invalid_rejection, reason})
    end
  end

  defp log_apply(state, "checkpoint", op, entry) do
    with {:ok, record} <- fetch_op(state, op),
         :ok <- validate_attempt(entry["attempt"], state),
         :ok <- validate_revision(entry["expected_revision"]),
         :ok <- validate_checkpoint(entry["checkpoint"], state),
         :ok <- expect_revision(record, entry["expected_revision"]) do
      if record.outcome == nil and not record.checkpoint_active and
           entry["attempt"] == current_attempt(record) and
           entry["attempt"] not in record.released do
        record = %{
          record
          | checkpoint: entry["checkpoint"],
            checkpoint_active: true,
            checkpoint_decision: nil,
            checkpointed_attempts: Enum.uniq(record.checkpointed_attempts ++ [entry["attempt"]]),
            revision: record.revision + 1
        }

        {:ok, %{state | ops: Map.put(state.ops, op, record)}}
      else
        migration_required(state, op, :invalid_checkpoint)
      end
    end
  end

  defp log_apply(state, "checkpoint_update", op, entry) do
    with {:ok, record} <- fetch_op(state, op),
         :ok <- validate_revision(entry["expected_revision"]),
         :ok <- validate_checkpoint(entry["checkpoint"], state),
         :ok <- expect_revision(record, entry["expected_revision"]) do
      if record.outcome == nil and record.checkpoint_active do
        record = %{record | checkpoint: entry["checkpoint"], revision: record.revision + 1}
        {:ok, %{state | ops: Map.put(state.ops, op, record)}}
      else
        migration_required(state, op, :invalid_checkpoint_update)
      end
    end
  end

  defp log_apply(state, "checkpoint_resume", op, entry) do
    with {:ok, record} <- fetch_op(state, op),
         :ok <- expect_revision(record, entry["expected_revision"]),
         :ok <- validate_checkpoint(entry["decision"], state) do
      if record.checkpoint_active do
        record = %{
          record
          | checkpoint_decision: entry["decision"],
            checkpoint_active: false,
            checkpoint_grant_revision: record.revision + 1,
            released: Enum.uniq(record.released ++ [current_attempt(record)]),
            revision: record.revision + 1
        }

        {:ok, %{state | ops: Map.put(state.ops, op, record)}}
      else
        migration_required(state, op, :not_checkpointed)
      end
    end
  end

  defp log_apply(state, "reconcile", op, entry) do
    with {:ok, record} <- fetch_op(state, op),
         :ok <- expect_revision(record, entry["expected_revision"]),
         {:ok, resolution} <- reconciliation_resolution(entry["resolution"]),
         :ok <- validate_evidence(entry["evidence"] || %{}, state) do
      record = apply_reconciliation(record, resolution, entry["evidence"] || %{})
      {:ok, %{state | ops: Map.put(state.ops, op, record)}}
    end
  end

  defp log_apply(_state, _type, _op, _entry), do: {:error, :bad_entry}

  defp migration_required(state, op, reason) do
    {:error, {:ledger_migration_required, state.id, op, reason}}
  end

  defp apply_rejection(state, op, entry) do
    with {:ok, record} <- fetch_op(state, op),
         :ok <- validate_revision(entry["expected_revision"]),
         :ok <- expect_revision(record, entry["expected_revision"]),
         :ok <- validate_attempt(entry["attempt"], state),
         :ok <- validate_evidence(entry["evidence"] || %{}, state) do
      cond do
        record.outcome != nil ->
          {:error, :already_decided}

        active_attempt?(record) ->
          {:error, :attempt_in_flight}

        length(record.attempts) >= state.max_attempts ->
          {:error, :attempt_history_full}

        entry["attempt"] in record.attempts ->
          {:error, :duplicate_attempt}

        true ->
          outcome = {:rejected_before_dispatch, entry["evidence"], entry["attempt"]}

          record = %{
            record
            | attempts: record.attempts ++ [entry["attempt"]],
              outcome: outcome,
              revision: record.revision + 1
          }

          {:ok, %{state | ops: Map.put(state.ops, op, record)}}
      end
    end
  end

  defp outcome_class("completed"), do: {:ok, :completed}
  defp outcome_class("rejected_before_dispatch"), do: {:ok, :rejected_before_dispatch}
  defp outcome_class("failed_known"), do: {:ok, :failed_known}
  defp outcome_class("unknown"), do: {:ok, :unknown}
  defp outcome_class("requires_operator"), do: {:ok, :requires_operator}
  defp outcome_class(other), do: {:error, {:invalid_outcome_class, other}}

  defp reconciliation_resolution("confirmed_committed"), do: {:ok, :confirmed_committed}
  defp reconciliation_resolution("confirmed_failed"), do: {:ok, :confirmed_failed}
  defp reconciliation_resolution("retry_permitted"), do: {:ok, :retry_permitted}
  defp reconciliation_resolution(other), do: {:error, {:invalid_resolution, other}}

  defp append(state, record) do
    encoded = JSON.encode!(record)
    append_bytes = byte_size(encoded) + 1

    with :ok <- validate_record_bytes(encoded, state),
         :ok <- ensure_log_room(state, append_bytes) do
      case DurableLog.append(state.path, [encoded, "\n"]) do
        :ok -> :ok
        {:error, reason} -> {:error, {:ledger_write_failed, reason}}
      end
    else
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:ledger_unencodable, Exception.message(error)}}
  end

  defp rejection_attempt(op_key) do
    digest = :crypto.hash(:sha256, op_key) |> Base.url_encode64(padding: false)
    "rejected-" <> digest
  end

  defp validate_record_bytes(encoded, state) do
    size = byte_size(encoded) + 1

    if size <= state.max_record_bytes,
      do: :ok,
      else: {:error, {:record_too_large, size, state.max_record_bytes}}
  end

  defp ensure_log_room(state, append_bytes) do
    case File.stat(state.path) do
      {:ok, %{size: current}} when current + append_bytes <= state.max_log_bytes ->
        :ok

      {:ok, %{size: current}} ->
        {:error, {:ledger_log_too_large, current + append_bytes, state.max_log_bytes}}

      {:error, reason} ->
        {:error, {:ledger_write_failed, reason}}
    end
  end

  defp log_path(dir, id), do: Path.join(dir, id <> ".jsonl")

  defp state_home do
    case System.get_env("ALTO_STATE_HOME") do
      path when is_binary(path) and path != "" ->
        path

      _other ->
        case System.get_env("XDG_STATE_HOME") do
          path when is_binary(path) and path != "" -> path
          _other -> Path.join(System.user_home!(), ".local/state")
        end
    end
  end
end
