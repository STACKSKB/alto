defmodule Alto.OperationLog do
  @moduledoc """
  A bounded, durable operation ledger.

  One pure transition function handles live commands and replay. Accepted
  events are appended before their state is published, so failed writes
  cannot expose invented progress. Open work is never evicted.
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

      Alto.Storage.start_server(__MODULE__, state, &load/1, opts)
    end
  end

  @spec dir(keyword()) :: Path.t()
  def dir(opts \\ []) do
    case Keyword.get(opts, :dir) do
      nil -> Path.join([Alto.Storage.state_home(), "alto", "operation_logs"])
      path when is_binary(path) -> path
    end
  end

  @spec record_intent(GenServer.server(), op_key(), binary(), binary() | nil, map() | nil) ::
          :ok | {:error, term()}
  def record_intent(server \\ __MODULE__, op_key, tool, inbox_key, recovery \\ nil) do
    call(server, {:intent, op_key, tool, inbox_key, recovery})
  end

  def record_intent(server, op_key, tool, inbox_key, recovery, timeout),
    do: call(server, {:intent, op_key, tool, inbox_key, recovery}, timeout)

  @spec record_attempt(GenServer.server(), op_key(), String.t()) :: :ok | {:error, term()}
  def record_attempt(server \\ __MODULE__, op_key, attempt_id) do
    call(server, {:attempt, op_key, attempt_id})
  end

  def record_attempt(server, op_key, attempt_id, timeout),
    do: call(server, {:attempt, op_key, attempt_id}, timeout)

  @spec record_release(GenServer.server(), op_key(), String.t()) :: :ok | {:error, term()}
  def record_release(server \\ __MODULE__, op_key, attempt_id) do
    call(server, {:release, op_key, attempt_id})
  end

  def record_release(server, op_key, attempt_id, timeout),
    do: call(server, {:release, op_key, attempt_id}, timeout)

  @spec record_outcome(
          GenServer.server(),
          op_key(),
          String.t(),
          Alto.Effect.Outcome.class(),
          map()
        ) ::
          :ok | {:error, term()}
  def record_outcome(server \\ __MODULE__, op_key, attempt_id, class, evidence \\ %{}) do
    call(server, {:outcome, op_key, attempt_id, class, evidence})
  end

  def record_outcome(server, op_key, attempt_id, class, evidence, timeout),
    do: call(server, {:outcome, op_key, attempt_id, class, evidence}, timeout)

  def record_checkpoint(server \\ __MODULE__, op_key, attempt_id, checkpoint) do
    call(server, {:checkpoint, op_key, attempt_id, checkpoint})
  end

  def record_checkpoint(server, op_key, attempt_id, checkpoint, timeout),
    do: call(server, {:checkpoint, op_key, attempt_id, checkpoint}, timeout)

  def update_checkpoint(server \\ __MODULE__, op_key, expected_revision, checkpoint) do
    call(server, {:checkpoint_update, op_key, expected_revision, checkpoint})
  end

  def update_checkpoint(server, op_key, expected_revision, checkpoint, timeout),
    do: call(server, {:checkpoint_update, op_key, expected_revision, checkpoint}, timeout)

  def resume_checkpoint(server \\ __MODULE__, op_key, expected_revision, decision) do
    call(server, {:resume_checkpoint, op_key, expected_revision, decision})
  end

  def resume_checkpoint(server, op_key, expected_revision, decision, timeout),
    do: call(server, {:resume_checkpoint, op_key, expected_revision, decision}, timeout)

  @spec status(GenServer.server(), op_key()) :: status()
  def status(server \\ __MODULE__, op_key) do
    call(server, {:status, op_key})
  end

  @spec attempts(GenServer.server(), op_key()) :: non_neg_integer()
  def attempts(server \\ __MODULE__, op_key) do
    call(server, {:attempts, op_key})
  end

  @spec reject_intended(GenServer.server(), op_key(), pos_integer(), map()) ::
          :ok | {:error, term()}
  def reject_intended(server \\ __MODULE__, op_key, expected_revision, evidence \\ %{}) do
    call(server, {:reject_intended, op_key, expected_revision, evidence})
  end

  @spec keys(GenServer.server()) :: [op_key()]
  def keys(server \\ __MODULE__) do
    call(server, :keys)
  end

  @spec keys(GenServer.server(), timeout()) :: [op_key()]
  def keys(server, timeout), do: call(server, :keys, timeout)

  @doc "Bounded canonical operation views, oldest first."
  @spec entries(GenServer.server(), :all | :open | :parked, timeout()) :: [map()]
  def entries(server \\ __MODULE__, filter \\ :all, timeout \\ 5_000)
      when filter in [:all, :open, :parked] do
    call(server, {:entries, filter}, timeout)
  end

  @spec recovery(GenServer.server(), op_key()) :: {:ok, map()} | {:error, :not_found}
  def recovery(server \\ __MODULE__, op_key, timeout \\ 5_000) do
    call(server, {:recovery, op_key}, timeout)
  end

  def identity(server \\ __MODULE__, timeout \\ 5_000) do
    call(server, :identity, timeout)
  end

  @spec reconcile(GenServer.server(), op_key(), pos_integer(), atom(), map()) ::
          {:ok, map()} | {:error, term()}
  def reconcile(server \\ __MODULE__, op_key, expected_revision, resolution, evidence \\ %{}) do
    call(server, {:reconcile, op_key, expected_revision, resolution, evidence})
  end

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
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(request, _from, state) do
    case to_event(request, state) do
      {:ok, event} -> commit(state, event)
      :read -> read(request, state)
    end
  end

  defp to_event({:intent, op, tool, inbox, recovery}, _state) do
    {:ok,
     event("intent", op, %{
       "tool" => tool,
       "inbox" => inbox,
       "recovery" => encode_recovery(recovery)
     })}
  end

  defp to_event({type, op, attempt}, _state) when type in [:attempt, :release],
    do: {:ok, event(Atom.to_string(type), op, %{"attempt" => attempt})}

  defp to_event({:outcome, op, attempt, class, evidence}, _state),
    do:
      {:ok,
       event("outcome", op, %{
         "attempt" => attempt,
         "class" => class,
         "evidence" => if(is_map(evidence), do: scrub(evidence), else: evidence)
       })}

  defp to_event({:checkpoint, op, attempt, checkpoint}, _state),
    do: {:ok, event("checkpoint", op, %{"attempt" => attempt, "checkpoint" => checkpoint})}

  defp to_event({type, op, revision, value}, _state)
       when type in [:checkpoint_update, :resume_checkpoint] do
    {name, field} =
      if type == :checkpoint_update,
        do: {"checkpoint_update", "checkpoint"},
        else: {"checkpoint_resume", "decision"}

    {:ok, event(name, op, %{"expected_revision" => revision, field => value})}
  end

  defp to_event({:reject_intended, op, revision, evidence}, _state),
    do:
      {:ok,
       event("reject", op, %{
         "expected_revision" => revision,
         "evidence" => if(is_map(evidence), do: scrub(evidence), else: evidence)
       })}

  defp to_event({:reconcile, op, revision, resolution, evidence}, _state),
    do:
      {:ok,
       event("reconcile", op, %{
         "expected_revision" => revision,
         "resolution" => resolution,
         "evidence" => if(is_map(evidence), do: scrub(evidence), else: evidence)
       })}

  defp to_event(_, _), do: :read

  defp event(type, op, fields),
    do:
      Map.merge(
        %{"v" => @version, "t" => type, "op" => op, "at_ms" => System.system_time(:millisecond)},
        fields
      )

  # Derive the transition, durably append it, then publish it.
  defp commit(state, event) do
    with {:ok, planned} <- plan(state, event),
         do: persist(state, planned, event),
         else: ({:error, reason} -> {:reply, {:error, reason}, state})
  end

  defp persist(original, planned, event) do
    case transition(planned, event) do
      {:ok, ^planned, :noop} ->
        {:reply, :ok, original}

      {:ok, next, response} ->
        case append(original, event) do
          :ok -> {:reply, response(response, event, next), next}
          {:error, reason} -> {:reply, {:error, reason}, original}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, original}
    end
  end

  defp response(:ok, _, _), do: :ok

  defp response(:view, %{"op" => op}, state),
    do: {:ok, recovery_view(op, Map.fetch!(state.ops, op))}

  defp read({:status, op}, state), do: {:reply, read_status(state, op), state}

  defp read({:attempts, op}, state),
    do: {:reply, length(Map.get(state.ops, op, %{attempts: []}).attempts), state}

  defp read(:keys, state), do: {:reply, state.order, state}

  defp read({:entries, filter}, state) do
    entries =
      state.order
      |> Enum.map(&recovery_view(&1, Map.fetch!(state.ops, &1)))
      |> Enum.filter(&entry_matches?(&1, filter))

    {:reply, entries, state}
  end

  defp read({:recovery, op}, state) do
    result =
      case Map.fetch(state.ops, op) do
        {:ok, entry} -> {:ok, recovery_view(op, entry)}
        :error -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  defp read(:identity, state),
    do:
      {:reply,
       {:ok,
        %{"kind" => "alto_operation_log", "id" => state.id, "dir" => Path.expand(state.dir)}},
       state}

  ## Internals

  defp call(server, request, timeout \\ 5_000) do
    GenServer.call(server, request, timeout)
  end

  defp read_status(state, op_key) do
    case Map.fetch(state.ops, op_key) do
      :error -> :no_intent
      {:ok, entry} -> entry_status(entry)
    end
  end

  defp entry_status(%{phase: :checkpointed, checkpoint: checkpoint, attempts: attempts}),
    do: {:checkpointed, checkpoint, List.last(attempts)}

  defp entry_status(%{phase: :intended}), do: {:intended}

  defp entry_status(%{phase: :dispatched, attempts: attempts}),
    do: {:dispatched, List.last(attempts)}

  defp entry_status(%{phase: {:decided, class, evidence, _attempt}}),
    do: {:decided, class, evidence}

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

  defp active_attempt?(%{phase: phase}) when phase in [:dispatched, :checkpointed], do: true

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
      current_attempt: current_attempt(entry),
      outcome: phase_outcome(entry.phase),
      checkpoint: entry.checkpoint,
      checkpoint_decision: entry.checkpoint_decision,
      checkpoint_grant_revision: entry.checkpoint_grant_revision,
      checkpointed_attempts: entry.checkpointed_attempts,
      attempts: length(entry.attempts)
    }
  end

  defp phase_outcome({:decided, class, evidence, attempt}), do: {class, evidence, attempt}
  defp phase_outcome(_phase), do: nil

  defp entry_matches?(_entry, :all), do: true
  defp entry_matches?(%{status: {:intended}, attempts: 0}, :open), do: true

  defp entry_matches?(%{status: {:dispatched, _}}, :open), do: true
  defp entry_matches?(%{status: {:checkpointed, _, _}}, :open), do: true

  defp entry_matches?(%{status: {:decided, :requires_operator, _}}, :parked), do: true
  defp entry_matches?(_entry, _filter), do: false

  defp expect_revision(%{revision: revision}, revision), do: :ok
  defp expect_revision(_entry, _expected), do: {:error, :stale_revision}

  defp ensure_reconcilable(%{phase: :checkpointed}), do: {:error, :checkpoint_active}

  defp ensure_reconcilable(%{phase: phase, attempts: [_ | _]})
       when phase in [:intended, :dispatched],
       do: :ok

  defp ensure_reconcilable(%{phase: {:decided, class, _evidence, _attempt}})
       when class in [:unknown, :requires_operator],
       do: :ok

  defp ensure_reconcilable(_entry), do: {:error, :not_reconcilable}

  defp ensure_retry_recoverable(%{recovery: recovery}, :retry_permitted) when is_map(recovery),
    do: :ok

  defp ensure_retry_recoverable(_entry, :retry_permitted), do: {:error, :recovery_unavailable}
  defp ensure_retry_recoverable(_entry, _resolution), do: :ok

  defp apply_reconciliation(entry, :retry_permitted, _evidence) do
    %{entry | phase: :intended}
  end

  defp apply_reconciliation(entry, resolution, evidence) do
    class = if resolution == :confirmed_committed, do: :completed, else: :failed_known
    attempt = current_attempt(entry) || "operator"
    audit = %{operator_resolution: resolution, evidence: evidence}
    %{entry | phase: {:decided, class, audit, attempt}}
  end

  defp outcome_can_be_escalated?({:unknown, _evidence, _attempt}, :requires_operator), do: true
  defp outcome_can_be_escalated?(_outcome, _class), do: false

  defp evictable?(%{phase: {:decided, class, _evidence, _attempt}})
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
  defp encode_recovery(nil), do: nil
  defp encode_recovery(recovery), do: SessionStore.encode_term(recovery)

  defp decode_recovery(nil), do: {:ok, nil}
  defp decode_recovery(recovery), do: SessionStore.decode_term(recovery)

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
    with :ok <- DurableLog.open(state.dir, state.path), do: replay(state)
  end

  defp replay(state) do
    case DurableLog.replay(state.path, state.max_log_bytes, &replay_lines(state, &1)) do
      :missing -> {:ok, state}
      {:read_error, {:too_large, size, max}} -> {:error, {:ledger_log_too_large, size, max}}
      {:read_error, reason} -> {:error, {:ledger_read_failed, reason}}
      result -> result
    end
  end

  defp replay_lines(state, lines) do
    Alto.JSONLines.fold(state, lines, &apply_logged/3)
  end

  defp apply_logged(state, line, number) do
    with :ok <- validate_record_bytes(line, state) do
      case JSON.decode(line) do
        {:ok, %{"v" => @version, "t" => type, "op" => op} = entry}
        when is_binary(type) and is_binary(op) ->
          with {:ok, planned} <- replay_plan(state, entry),
               {:ok, state, _reply} <- transition(planned, entry),
               do: {:ok, state}

        _other ->
          {:error, {:ledger_corrupt, state.id, number}}
      end
    end
  end

  defp replay_plan(state, event) do
    case plan(state, event) do
      {:error, :ledger_full} ->
        {:error, {:ledger_capacity_exceeded, map_size(state.ops) + 1, state.max_ops}}

      result ->
        result
    end
  end

  defp plan(state, %{"t" => "intent", "op" => op}) do
    if Map.has_key?(state.ops, op), do: {:ok, state}, else: ensure_room(state)
  end

  defp plan(state, _event), do: {:ok, state}

  # The same pure state transition serves live commands and durable replay.
  defp transition(state, %{"t" => type, "op" => op} = entry) do
    with :ok <- validate_key(op),
         current <- Map.get(state.ops, op),
         {:ok, record} <- log_apply(current, type, entry, state) do
      record = Map.put(record, :revision, if(current, do: current.revision + 1, else: 1))
      order = if is_nil(current), do: state.order ++ [op], else: state.order
      next = %{state | ops: Map.put(state.ops, op, record), order: order}
      {:ok, next, transition_reply(type)}
    else
      :noop -> {:ok, state, :noop}
      error -> error
    end
  end

  defp transition_reply(type)
       when type in ["checkpoint_update", "checkpoint_resume", "reconcile"],
       do: :view

  defp transition_reply(_type), do: :ok

  defp log_apply(nil, type, _entry, _state) when type != "intent", do: {:error, :no_intent}

  defp log_apply(record, "intent", entry, state) do
    with {:ok, recovery} <- decode_recovery(entry["recovery"]),
         :ok <- validate_tool(entry["tool"], state),
         :ok <- validate_inbox(entry["inbox"], state),
         :ok <- validate_recovery(recovery, state) do
      if is_nil(record) do
        {:ok,
         %{
           tool: entry["tool"],
           inbox: entry["inbox"],
           recovery: recovery,
           attempts: [],
           phase: :intended,
           checkpoint: nil,
           checkpoint_decision: nil,
           checkpointed_attempts: [],
           checkpoint_grant_revision: nil
         }}
      else
        if same_intent?(record, entry["tool"], entry["inbox"], recovery),
          do: :noop,
          else: {:error, :intent_conflict}
      end
    end
  end

  defp log_apply(record, "attempt", entry, state) do
    with :ok <- validate_attempt(entry["attempt"], state) do
      attempt = entry["attempt"]

      cond do
        match?({:decided, _, _, _}, record.phase) ->
          {:error, :already_decided}

        record.phase == :checkpointed ->
          {:error, :checkpoint_active}

        attempt in record.attempts ->
          if attempt == current_attempt(record) and active_attempt?(record),
            do: :noop,
            else: {:error, :stale_attempt}

        active_attempt?(record) ->
          {:error, :attempt_in_flight}

        length(record.attempts) >= state.max_attempts ->
          {:error, :attempt_history_full}

        true ->
          {:ok, %{record | attempts: record.attempts ++ [attempt], phase: :dispatched}}
      end
    end
  end

  defp log_apply(record, "release", entry, state) do
    with :ok <- validate_attempt(entry["attempt"], state) do
      attempt = entry["attempt"]

      cond do
        attempt not in record.attempts -> {:error, :no_attempt}
        match?({:decided, _, _, _}, record.phase) -> {:error, :already_decided}
        record.phase == :checkpointed -> {:error, :checkpoint_active}
        attempt != current_attempt(record) -> {:error, :stale_attempt}
        record.phase == :intended -> :noop
        true -> {:ok, %{record | phase: :intended}}
      end
    end
  end

  defp log_apply(record, "outcome", entry, state) do
    with :ok <- validate_attempt(entry["attempt"], state),
         :ok <- validate_evidence(entry["evidence"], state),
         {:ok, class} <- outcome_class(entry["class"]) do
      attempt = entry["attempt"]

      cond do
        record.attempts == [] ->
          {:error, :no_attempt}

        match?({:decided, _, _, _}, record.phase) and
            not outcome_can_be_escalated?(phase_outcome(record.phase), class) ->
          {:error, :already_decided}

        record.phase == :checkpointed ->
          {:error, :checkpoint_active}

        attempt != current_attempt(record) or
            (record.phase != :dispatched and not match?({:decided, :unknown, _, _}, record.phase)) ->
          {:error, :stale_attempt}

        true ->
          {:ok, %{record | phase: {:decided, class, entry["evidence"], attempt}}}
      end
    end
  end

  defp log_apply(record, "reject", entry, state), do: apply_rejection(record, entry, state)

  defp log_apply(record, "checkpoint", entry, state) do
    with :ok <- validate_attempt(entry["attempt"], state),
         :ok <- validate_checkpoint(entry["checkpoint"], state),
         do: checkpoint_transition(record, entry)
  end

  defp log_apply(record, "checkpoint_update", entry, state) do
    with :ok <- validate_revision(entry["expected_revision"]),
         :ok <- validate_checkpoint(entry["checkpoint"], state),
         :ok <- expect_revision(record, entry["expected_revision"]) do
      if record.phase == :checkpointed do
        {:ok, %{record | checkpoint: entry["checkpoint"]}}
      else
        {:error, :not_checkpointed}
      end
    end
  end

  defp log_apply(record, "checkpoint_resume", entry, state) do
    with :ok <- validate_revision(entry["expected_revision"]),
         :ok <- validate_checkpoint(entry["decision"], state),
         :ok <- expect_revision(record, entry["expected_revision"]) do
      if record.phase == :checkpointed do
        {:ok,
         %{
           record
           | checkpoint_decision: entry["decision"],
             phase: :intended,
             checkpoint_grant_revision: record.revision + 1
         }}
      else
        {:error, :not_checkpointed}
      end
    end
  end

  defp log_apply(record, "reconcile", entry, state) do
    with :ok <- validate_revision(entry["expected_revision"]),
         {:ok, resolution} <- reconciliation_resolution(entry["resolution"]),
         :ok <- validate_evidence(entry["evidence"] || %{}, state),
         :ok <- expect_revision(record, entry["expected_revision"]),
         :ok <- ensure_reconcilable(record),
         :ok <- ensure_retry_recoverable(record, resolution) do
      {:ok, apply_reconciliation(record, resolution, entry["evidence"] || %{})}
    end
  end

  defp log_apply(_record, _type, _entry, _state), do: {:error, :bad_entry}

  defp checkpoint_transition(record, entry) do
    attempt = entry["attempt"]

    cond do
      match?({:decided, _, _, _}, record.phase) ->
        {:error, :already_decided}

      record.phase == :checkpointed ->
        {:error, :checkpoint_active}

      attempt != current_attempt(record) or record.phase != :dispatched ->
        {:error, :stale_attempt}

      true ->
        {:ok,
         %{
           record
           | checkpoint: entry["checkpoint"],
             phase: :checkpointed,
             checkpoint_decision: nil,
             checkpointed_attempts: Enum.uniq(record.checkpointed_attempts ++ [attempt])
         }}
    end
  end

  defp apply_rejection(record, entry, state) do
    attempt = entry["attempt"] || rejection_attempt(entry["op"])

    with :ok <- validate_revision(entry["expected_revision"]),
         :ok <- validate_attempt(attempt, state),
         :ok <- validate_evidence(entry["evidence"] || %{}, state),
         :ok <- expect_revision(record, entry["expected_revision"]) do
      cond do
        match?({:decided, _, _, _}, record.phase) ->
          {:error, :already_decided}

        active_attempt?(record) ->
          {:error, :attempt_in_flight}

        length(record.attempts) >= state.max_attempts ->
          {:error, :attempt_history_full}

        attempt in record.attempts ->
          {:error, :duplicate_attempt}

        true ->
          {:ok,
           %{
             record
             | attempts: record.attempts ++ [attempt],
               phase: {:decided, :rejected_before_dispatch, entry["evidence"], attempt}
           }}
      end
    end
  end

  defp outcome_class("completed"), do: {:ok, :completed}
  defp outcome_class("rejected_before_dispatch"), do: {:ok, :rejected_before_dispatch}
  defp outcome_class("failed_known"), do: {:ok, :failed_known}
  defp outcome_class("unknown"), do: {:ok, :unknown}
  defp outcome_class("requires_operator"), do: {:ok, :requires_operator}

  defp outcome_class(class) when is_atom(class) do
    with :ok <- validate_class(class), do: {:ok, class}
  end

  defp outcome_class(other), do: {:error, {:invalid_outcome_class, other}}

  defp reconciliation_resolution("confirmed_committed"), do: {:ok, :confirmed_committed}
  defp reconciliation_resolution("confirmed_failed"), do: {:ok, :confirmed_failed}
  defp reconciliation_resolution("retry_permitted"), do: {:ok, :retry_permitted}

  defp reconciliation_resolution(resolution) when is_atom(resolution) do
    with :ok <- validate_resolution(resolution), do: {:ok, resolution}
  end

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
end
