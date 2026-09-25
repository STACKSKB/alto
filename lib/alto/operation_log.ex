defmodule Alto.OperationLog do
  @moduledoc """
  A bounded, durable operation ledger.

  One native command representation serves live execution and replay. Accepted
  commands are appended before their state is published, so failed writes
  cannot expose invented progress. Open work is never evicted. Commands use
  bounded portable-term encoding inside a versioned JSONL envelope; evidence
  and checkpoints retain their exact keys and values across restarts. As with
  other portable stores, atoms must already be loaded when decoding.
  """

  use GenServer

  alias Alto.Persistence.Codec
  alias Alto.DurableLog

  @version 2
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  @max_key_bytes 256
  @limits [
    max_ops: [type: :non_neg_integer, default: 10_000],
    max_identifier_bytes: [type: :pos_integer, default: 256],
    max_evidence_bytes: [type: :pos_integer, default: 64_000],
    max_recovery_bytes: [type: :pos_integer, default: 64_000],
    max_record_bytes: [type: :pos_integer, default: 128_000],
    max_log_bytes: [type: :pos_integer, default: 64_000_000],
    max_attempts: [type: :pos_integer, default: 32]
  ]
  @limits_schema NimbleOptions.new!(@limits)
  @scrub_pattern ~r/password|secret|token|api_key|apikey|credential|private_key/i

  @enforce_keys [:id, :dir, :path] ++ Keyword.keys(@limits)
  defstruct @enforce_keys ++ [:lock, ops: %{}, order: []]

  @type op_key :: String.t()
  @type outcome_class ::
          :completed
          | :rejected_before_dispatch
          | :failed_known
          | :unknown
          | :requires_operator
  @type status ::
          :no_intent
          | {:intended}
          | {:dispatched, String.t()}
          | {:checkpointed, map(), String.t()}
          | {:decided, outcome_class(), map()}

  ## Client API

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    :ok = validate_id!(id)

    with {:ok, limits} <-
           NimbleOptions.validate(Keyword.take(opts, Keyword.keys(@limits)), @limits_schema) do
      directory = dir(opts)

      state =
        struct!(__MODULE__, [id: id, dir: directory, path: log_path(directory, id)] ++ limits)

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
  def record_intent(
        server \\ __MODULE__,
        op_key,
        tool,
        inbox_key,
        recovery \\ nil,
        timeout \\ 5_000
      ) do
    call(server, {:intent, op_key, tool, inbox_key, recovery}, timeout)
  end

  @doc "Create a retained checkpoint atomically if absent; an existing record is unchanged."
  def retain(server \\ __MODULE__, op_key, tool, recovery, attempt, checkpoint, timeout \\ 5_000) do
    call(server, {:retain, op_key, tool, recovery, attempt, checkpoint}, timeout)
  end

  @doc "Retire an internal checkpoint at an exact revision in one durable write."
  def retire_checkpoint(
        server \\ __MODULE__,
        op_key,
        revision,
        decision,
        attempt,
        evidence,
        timeout \\ 5_000
      ) do
    call(server, {:retire_checkpoint, op_key, revision, decision, attempt, evidence}, timeout)
  end

  @spec record_attempt(GenServer.server(), op_key(), String.t()) :: :ok | {:error, term()}
  def record_attempt(server \\ __MODULE__, op_key, attempt_id, timeout \\ 5_000) do
    call(server, {:attempt, op_key, attempt_id}, timeout)
  end

  @spec record_release(GenServer.server(), op_key(), String.t()) :: :ok | {:error, term()}
  def record_release(server \\ __MODULE__, op_key, attempt_id, timeout \\ 5_000) do
    call(server, {:release, op_key, attempt_id}, timeout)
  end

  @spec record_outcome(
          GenServer.server(),
          op_key(),
          String.t(),
          outcome_class(),
          map()
        ) ::
          :ok | {:error, term()}
  def record_outcome(
        server \\ __MODULE__,
        op_key,
        attempt_id,
        class,
        evidence \\ %{},
        timeout \\ 5_000
      ) do
    call(server, {:outcome, op_key, attempt_id, class, evidence}, timeout)
  end

  def record_checkpoint(server \\ __MODULE__, op_key, attempt_id, checkpoint, timeout \\ 5_000) do
    call(server, {:checkpoint, op_key, attempt_id, checkpoint}, timeout)
  end

  def update_checkpoint(
        server \\ __MODULE__,
        op_key,
        expected_revision,
        checkpoint,
        timeout \\ 5_000
      ) do
    call(server, {:checkpoint_update, op_key, expected_revision, checkpoint}, timeout)
  end

  def resume_checkpoint(
        server \\ __MODULE__,
        op_key,
        expected_revision,
        decision,
        timeout \\ 5_000
      ) do
    call(server, {:resume_checkpoint, op_key, expected_revision, decision}, timeout)
  end

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

  @spec keys(GenServer.server(), timeout()) :: [op_key()]
  def keys(server \\ __MODULE__, timeout \\ 5_000), do: call(server, :keys, timeout)

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

  @commands %{
    intent: 5,
    retain: 6,
    retire_checkpoint: 6,
    attempt: 3,
    release: 3,
    outcome: 5,
    checkpoint: 4,
    checkpoint_update: 4,
    resume_checkpoint: 4,
    reject_intended: 4,
    reconcile: 5
  }

  @impl true
  def handle_call(request, _from, state) do
    if command?(request), do: commit(state, scrub_command(request)), else: read(request, state)
  end

  defp command?(request) when is_tuple(request) and tuple_size(request) > 0,
    do: Map.get(@commands, elem(request, 0)) == tuple_size(request)

  defp command?(_), do: false

  defp scrub_command(command)
       when elem(command, 0) in [:outcome, :reject_intended, :reconcile, :retire_checkpoint] do
    index = tuple_size(command) - 1
    evidence = elem(command, index)
    if is_map(evidence), do: put_elem(command, index, scrub(evidence)), else: command
  end

  defp scrub_command(command), do: command

  # Derive the transition, durably append it, then publish it.
  defp commit(state, command) do
    case transition(state, command) do
      {:ok, _next, :noop} ->
        {:reply, :ok, state}

      {:ok, next, response} ->
        case append(state, command) do
          :ok -> {:reply, response(response, command, next), next}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp response(:ok, _, _), do: :ok

  defp response(:view, command, state) do
    op = elem(command, 1)
    {:ok, recovery_view(op, Map.fetch!(state.ops, op))}
  end

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
    entry.tool == tool and entry.inbox == inbox and entry.recovery === recovery
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
    if :erlang.external_size(value) <= state.max_recovery_bytes,
      do: :ok,
      else: {:error, :invalid_checkpoint}
  end

  defp validate_checkpoint(_value, _state), do: {:error, :invalid_checkpoint}

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
        {:ok, %{"v" => @version, "command" => encoded}} ->
          with {:ok, command} <- Codec.decode(encoded, max_bytes: state.max_record_bytes),
               true <- command?(command) do
            case transition(state, command) do
              {:ok, state, _reply} ->
                {:ok, state}

              {:error, :ledger_full} ->
                {:error, {:ledger_capacity_exceeded, map_size(state.ops) + 1, state.max_ops}}

              error ->
                error
            end
          else
            _ -> {:error, {:ledger_corrupt, state.id, number}}
          end

        _other ->
          {:error, {:ledger_corrupt, state.id, number}}
      end
    end
  end

  defp maybe_make_room(state, command) when elem(command, 0) in [:intent, :retain] do
    if Map.has_key?(state.ops, elem(command, 1)), do: {:ok, state}, else: ensure_room(state)
  end

  defp maybe_make_room(state, _command), do: {:ok, state}

  # The same pure state transition serves live commands and durable replay.
  defp transition(state, command) do
    op = elem(command, 1)

    with {:ok, state} <- maybe_make_room(state, command),
         :ok <- validate_key(op),
         current <- Map.get(state.ops, op),
         {:ok, record} <- log_apply(current, command, state) do
      record = Map.put(record, :revision, if(current, do: current.revision + 1, else: 1))
      order = if is_nil(current), do: state.order ++ [op], else: state.order
      next = %{state | ops: Map.put(state.ops, op, record), order: order}
      {:ok, next, transition_reply(elem(command, 0))}
    else
      :noop -> {:ok, state, :noop}
      error -> error
    end
  end

  defp transition_reply(type)
       when type in [:checkpoint_update, :resume_checkpoint, :reconcile],
       do: :view

  defp transition_reply(_type), do: :ok

  defp log_apply(nil, {:retain, op, tool, recovery, attempt, checkpoint}, state) do
    with {:ok, record} <- log_apply(nil, {:intent, op, tool, nil, recovery}, state),
         {:ok, record} <- log_apply(record, {:attempt, op, attempt}, state),
         do: log_apply(record, {:checkpoint, op, attempt, checkpoint}, state)
  end

  defp log_apply(_record, {:retain, _, _, _, _, _}, _state), do: :noop

  defp log_apply(nil, command, _state) when elem(command, 0) != :intent,
    do: {:error, :no_intent}

  defp log_apply(record, {:intent, _op, tool, inbox, recovery}, state) do
    with :ok <- validate_tool(tool, state),
         :ok <- validate_inbox(inbox, state),
         :ok <- validate_recovery(recovery, state) do
      if is_nil(record) do
        {:ok,
         %{
           tool: tool,
           inbox: inbox,
           recovery: recovery,
           attempts: [],
           phase: :intended,
           checkpoint: nil,
           checkpoint_decision: nil,
           checkpointed_attempts: [],
           checkpoint_grant_revision: nil
         }}
      else
        if same_intent?(record, tool, inbox, recovery),
          do: :noop,
          else: {:error, :intent_conflict}
      end
    end
  end

  defp log_apply(record, {:attempt, _op, attempt}, state) do
    with :ok <- validate_attempt(attempt, state) do
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

  defp log_apply(record, {:release, _op, attempt}, state) do
    with :ok <- validate_attempt(attempt, state) do
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

  defp log_apply(record, {:outcome, _op, attempt, class, evidence}, state) do
    with :ok <- validate_attempt(attempt, state),
         :ok <- validate_evidence(evidence, state),
         {:ok, class} <- outcome_class(class) do
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
          {:ok, %{record | phase: {:decided, class, evidence, attempt}}}
      end
    end
  end

  defp log_apply(record, {:checkpoint, _op, attempt, checkpoint}, state) do
    with :ok <- validate_attempt(attempt, state),
         :ok <- validate_checkpoint(checkpoint, state),
         do: checkpoint_transition(record, attempt, checkpoint)
  end

  defp log_apply(record, {:checkpoint_update, _op, expected_revision, checkpoint}, state) do
    with :ok <- validate_revision(expected_revision),
         :ok <- validate_checkpoint(checkpoint, state),
         :ok <- expect_revision(record, expected_revision) do
      if record.phase == :checkpointed do
        {:ok, %{record | checkpoint: checkpoint}}
      else
        {:error, :not_checkpointed}
      end
    end
  end

  defp log_apply(record, {:resume_checkpoint, _op, expected_revision, decision}, state) do
    with :ok <- validate_revision(expected_revision),
         :ok <- validate_checkpoint(decision, state),
         :ok <- expect_revision(record, expected_revision) do
      if record.phase == :checkpointed do
        {:ok,
         %{
           record
           | checkpoint_decision: decision,
             phase: :intended,
             checkpoint_grant_revision: record.revision + 1
         }}
      else
        {:error, :not_checkpointed}
      end
    end
  end

  defp log_apply(record, {:reconcile, _op, expected_revision, resolution, evidence}, state) do
    with :ok <- validate_revision(expected_revision),
         {:ok, resolution} <- reconciliation_resolution(resolution),
         :ok <- validate_evidence(evidence, state),
         :ok <- expect_revision(record, expected_revision),
         :ok <- ensure_reconcilable(record),
         :ok <- ensure_retry_recoverable(record, resolution) do
      {:ok, apply_reconciliation(record, resolution, evidence)}
    end
  end

  defp log_apply(record, {:reject_intended, op, expected_revision, evidence}, state) do
    attempt = rejection_attempt(op)

    with :ok <- validate_revision(expected_revision),
         :ok <- validate_attempt(attempt, state),
         :ok <- validate_evidence(evidence, state),
         :ok <- expect_revision(record, expected_revision) do
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
               phase: {:decided, :rejected_before_dispatch, evidence, attempt}
           }}
      end
    end
  end

  defp log_apply(record, {:retire_checkpoint, op, revision, decision, attempt, evidence}, state) do
    with {:ok, record} <- log_apply(record, {:resume_checkpoint, op, revision, decision}, state),
         {:ok, record} <- log_apply(record, {:attempt, op, attempt}, state),
         do: log_apply(record, {:outcome, op, attempt, :completed, evidence}, state)
  end

  defp log_apply(_record, _command, _state), do: {:error, :bad_entry}

  defp checkpoint_transition(record, attempt, checkpoint) do
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
           | checkpoint: checkpoint,
             phase: :checkpointed,
             checkpoint_decision: nil,
             checkpointed_attempts: Enum.uniq(record.checkpointed_attempts ++ [attempt])
         }}
    end
  end

  defp outcome_class(class)
       when class in [
              :completed,
              :rejected_before_dispatch,
              :failed_known,
              :unknown,
              :requires_operator
            ],
       do: {:ok, class}

  defp outcome_class(other), do: {:error, {:invalid_outcome_class, other}}

  defp reconciliation_resolution(resolution)
       when resolution in [:confirmed_committed, :confirmed_failed, :retry_permitted],
       do: {:ok, resolution}

  defp reconciliation_resolution(other), do: {:error, {:invalid_resolution, other}}

  defp append(state, command) do
    with {:ok, payload} <- Codec.encode(command, max_bytes: :erlang.external_size(command)),
         encoded <-
           JSON.encode!(%{
             "v" => @version,
             "command" => payload,
             "at_ms" => System.system_time(:millisecond)
           }),
         :ok <- validate_record_bytes(encoded, state),
         :ok <- ensure_log_room(state, byte_size(encoded) + 1) do
      case DurableLog.append(state.path, [encoded, "\n"]) do
        :ok -> :ok
        {:error, reason} -> {:error, {:ledger_write_failed, reason}}
      end
    else
      {:error, :not_portable_or_too_large} -> {:error, {:ledger_unencodable, :not_portable}}
      error -> error
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
