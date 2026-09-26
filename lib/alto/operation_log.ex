defmodule Alto.OperationLog do
  @moduledoc """
  A bounded, durable operation ledger sharing commands between live execution
  and replay. Commands append before state publication; open work is never evicted.
  Evidence and checkpoints retain exact portable terms, whose atoms must already
  be loaded when decoding.
  """

  use GenServer

  alias Alto.Persistence.Codec
  alias Alto.DurableLog

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
  @type revision :: pos_integer() | {pos_integer(), binary()}
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
  def dir(opts \\ []), do: Alto.Storage.dir("operation_logs", Keyword.get(opts, :dir))

  @type request ::
          {:intent, op_key(), binary(), binary() | nil, map() | nil}
          | {:retain, op_key(), binary(), map() | nil, binary(), map()}
          | {:retire_checkpoint, op_key(), revision(), map(), binary(), map()}
          | {:attempt, op_key(), binary()}
          | {:release, op_key(), binary()}
          | {:outcome, op_key(), binary(), outcome_class(), map()}
          | {:checkpoint, op_key(), binary(), map()}
          | {:checkpoint_update, op_key(), revision(), map()}
          | {:resume_checkpoint, op_key(), revision(), map()}
          | {:status, op_key()}
          | {:attempts, op_key()}
          | {:reject_intended, op_key(), revision(), map()}
          | {:entries, :all | :open | :parked}
          | {:recovery, op_key()}
          | :identity
          | {:reconcile, op_key(), revision(), atom(), map()}

  @doc """
  Execute a native ledger request. Mutation tuples are the same commands written
  to the durable log; validation, evidence scrubbing, revision checks, and durable
  publication happen in the ledger process. Supply all tuple fields explicitly,
  including absent recovery (`nil`) and empty evidence (`%{}`). Revision fences
  may pair the revision with a recovery generation to prevent writes after key reuse.

  `:retain` atomically creates a checkpoint if absent and leaves an existing
  record unchanged. `:retire_checkpoint` retires one at its exact revision.
  `{:entries, filter}` returns bounded canonical views, oldest first, with
  `:all`, `:open`, or `:parked`; invalid filters fail before contacting the ledger.
  `{:recovery, key}` reads one view, and `:identity` reads the store identity.
  Calls use a 5,000 ms timeout unless explicitly overridden.
  """
  @spec request(GenServer.server(), request(), timeout()) ::
          :ok | status() | non_neg_integer() | [map()] | {:ok, map()} | {:error, term()}
  def request(server, message, timeout \\ 5_000)

  def request(server, {:entries, filter} = message, timeout)
      when filter in [:all, :open, :parked],
      do: GenServer.call(server, message, timeout)

  def request(server, message, timeout)
      when not is_tuple(message) or tuple_size(message) != 2 or elem(message, 0) != :entries,
      do: GenServer.call(server, message, timeout)

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

  # Fields after the operation key. The same validation runs for live commands,
  # replay and compound transitions; revision fields also fence the current record.
  @commands %{
    intent: [:tool, :inbox, :recovery],
    retain: [:tool, :recovery, :attempt, :checkpoint],
    retire_checkpoint: [:revision, :checkpoint, :attempt, :evidence],
    attempt: [:attempt],
    release: [:attempt],
    outcome: [:attempt, :outcome, :evidence],
    checkpoint: [:attempt, :checkpoint],
    checkpoint_update: [:revision, :checkpoint],
    resume_checkpoint: [:revision, :checkpoint],
    reject_intended: [:revision, :evidence],
    reconcile: [:revision, :resolution, :evidence]
  }

  @impl true
  def handle_call(request, _from, state) do
    if command?(request), do: commit(state, scrub_command(request)), else: read(request, state)
  end

  defp command?(request) when is_tuple(request) and tuple_size(request) > 0,
    do:
      length(Map.get(@commands, elem(request, 0), [])) + 2 == tuple_size(request) and
        Map.has_key?(@commands, elem(request, 0))

  defp command?(_), do: false

  defp scrub_command(command)
       when elem(command, 0) in [:outcome, :reject_intended, :reconcile, :retire_checkpoint] do
    index = tuple_size(command) - 1
    evidence = elem(command, index)
    if is_map(evidence), do: put_elem(command, index, scrub(evidence)), else: command
  end

  defp scrub_command(command), do: command

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

  defp read_status(state, op_key) do
    case Map.fetch(state.ops, op_key) do
      :error -> :no_intent
      {:ok, entry} -> entry_status(entry)
    end
  end

  defp entry_status(%{phase: :checkpointed, checkpoint: checkpoint, attempts: attempts}),
    do: {:checkpointed, checkpoint, List.first(attempts)}

  defp entry_status(%{phase: :intended}), do: {:intended}

  defp entry_status(%{phase: :dispatched, attempts: attempts}),
    do: {:dispatched, List.first(attempts)}

  defp entry_status(%{phase: {:decided, class, evidence, _attempt}}),
    do: {:decided, class, evidence}

  defp ensure_room(state) do
    if map_size(state.ops) < state.max_ops do
      {:ok, state}
    else
      case Enum.find(state.order, &evictable?(Map.fetch!(state.ops, &1))) do
        nil ->
          {:error, :ledger_full}

        key ->
          {:ok, %{state | ops: Map.delete(state.ops, key), order: List.delete(state.order, key)}}
      end
    end
  end

  defp current_attempt(%{attempts: attempts}), do: List.first(attempts)

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

  defp expect_revision(
         %{revision: revision, recovery: %{"generation" => generation}},
         {revision, generation}
       ),
       do: :ok

  defp expect_revision(%{revision: revision}, revision), do: :ok
  defp expect_revision(_entry, _expected), do: {:error, :stale_revision}

  defp reconcilable?(%{phase: phase, attempts: [_ | _]})
       when phase in [:intended, :dispatched],
       do: true

  defp reconcilable?(%{phase: {:decided, class, _, _}})
       when class in [:unknown, :requires_operator],
       do: true

  defp reconcilable?(_), do: false

  defp evictable?(%{phase: {:decided, class, _evidence, _attempt}})
       when class in [:completed, :failed_known, :rejected_before_dispatch],
       do: true

  defp evictable?(_entry), do: false

  defp validate_key(key) when is_binary(key) do
    if byte_size(key) in 1..@max_key_bytes, do: :ok, else: {:error, {:invalid_op_key, key}}
  end

  defp validate_key(key), do: {:error, {:invalid_op_key, key}}

  defp validate(:tool, value, state),
    do: validate_identifier(value, :tool, state.max_identifier_bytes, :invalid_tool)

  defp validate(:inbox, nil, _), do: :ok

  defp validate(:inbox, value, state) do
    with :ok <- validate_key(value),
         do: validate_identifier(value, :inbox, state.max_identifier_bytes, :invalid_op_key)
  end

  defp validate(:attempt, value, state),
    do: validate_identifier(value, :attempt, state.max_identifier_bytes, :invalid_attempt)

  defp validate(:revision, value, _) when is_integer(value) and value >= 1, do: :ok

  defp validate(:revision, {revision, generation}, _)
       when is_integer(revision) and revision >= 1 and is_binary(generation),
       do: :ok

  defp validate(:recovery, nil, _), do: :ok

  defp validate(:outcome, value, _)
       when value in [
              :completed,
              :rejected_before_dispatch,
              :failed_known,
              :unknown,
              :requires_operator
            ],
       do: :ok

  defp validate(:resolution, value, _)
       when value in [:confirmed_committed, :confirmed_failed, :retry_permitted],
       do: :ok

  defp validate(field, value, state)
       when field in [:evidence, :recovery, :checkpoint] and is_map(value) do
    limit = if field == :evidence, do: state.max_evidence_bytes, else: state.max_recovery_bytes

    if :erlang.external_size(value) <= limit,
      do: :ok,
      else: {:error, {:field_too_large, field, limit}}
  end

  defp validate(field, value, _), do: {:error, {:invalid_field, field, value}}

  defp validate_identifier(value, kind, max, invalid) do
    cond do
      not is_binary(value) or value == "" -> {:error, {invalid, value}}
      byte_size(value) > max -> {:error, {:identifier_too_large, kind, max}}
      true -> :ok
    end
  end

  defp validate_id!(id) do
    if Alto.Storage.valid_id?(id) do
      :ok
    else
      raise ArgumentError, "invalid operation log id: #{inspect(id)}"
    end
  end

  ## Durable storage and replay

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
    with :ok <- validate_record_bytes(line, state),
         {:ok, encoded} when is_binary(encoded) <- JSON.decode(line),
         {:ok, command} <- Codec.decode(encoded, max_bytes: state.max_record_bytes),
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
      {:error, {:record_too_large, _, _}} = error -> error
      _ -> {:error, {:ledger_corrupt, state.id, number}}
    end
  end

  defp maybe_make_room(state, command) when elem(command, 0) in [:intent, :retain] do
    if Map.has_key?(state.ops, elem(command, 1)), do: {:ok, state}, else: ensure_room(state)
  end

  defp maybe_make_room(state, _command), do: {:ok, state}

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

  defp log_apply(record, {:retain, _, _, _, _, _}, _) when not is_nil(record), do: :noop

  defp log_apply(nil, command, _) when elem(command, 0) not in [:intent, :retain],
    do: {:error, :no_intent}

  defp log_apply(record, command, state) do
    [kind, _op | args] = Tuple.to_list(command)

    validation =
      Enum.zip(@commands[kind], args)
      |> Enum.reduce_while(:ok, fn {field, value}, :ok ->
        result =
          with :ok <- validate(field, value, state),
               do: if(field == :revision, do: expect_revision(record, value), else: :ok)

        case result do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    with :ok <- validation, do: apply_command(record, command, state)
  end

  defp apply_command(nil, {:intent, _op, tool, inbox, recovery}, _) do
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
  end

  defp apply_command(record, {:intent, _op, tool, inbox, recovery}, _) do
    if record.tool == tool and record.inbox == inbox and record.recovery === recovery,
      do: :noop,
      else: {:error, :intent_conflict}
  end

  defp apply_command(nil, {:retain, op, tool, recovery, attempt, checkpoint}, state),
    do:
      sequence(
        nil,
        [
          {:intent, op, tool, nil, recovery},
          {:attempt, op, attempt},
          {:checkpoint, op, attempt, checkpoint}
        ],
        state
      )

  defp apply_command(%{phase: :dispatched, attempts: [attempt | _]}, {:attempt, _, attempt}, _),
    do: :noop

  defp apply_command(%{phase: :intended} = record, {:attempt, _, attempt}, state) do
    cond do
      attempt in record.attempts -> {:error, :invalid_operation_state}
      length(record.attempts) >= state.max_attempts -> {:error, :attempt_history_full}
      true -> {:ok, %{record | attempts: [attempt | record.attempts], phase: :dispatched}}
    end
  end

  defp apply_command(%{phase: :intended, attempts: [attempt | _]}, {:release, _, attempt}, _),
    do: :noop

  defp apply_command(
         %{phase: :dispatched, attempts: [attempt | _]} = record,
         {:release, _, attempt},
         _
       ),
       do: {:ok, %{record | phase: :intended}}

  defp apply_command(
         %{phase: :dispatched, attempts: [attempt | _]} = record,
         {:outcome, _, attempt, class, evidence},
         _
       ),
       do: {:ok, %{record | phase: {:decided, class, evidence, attempt}}}

  defp apply_command(
         %{phase: {:decided, :unknown, _, attempt}, attempts: [attempt | _]} = record,
         {:outcome, _, attempt, :requires_operator, evidence},
         _
       ),
       do: {:ok, %{record | phase: {:decided, :requires_operator, evidence, attempt}}}

  defp apply_command(
         %{phase: :dispatched, attempts: [attempt | _]} = record,
         {:checkpoint, _, attempt, checkpoint},
         _
       ) do
    {:ok,
     %{
       record
       | checkpoint: checkpoint,
         phase: :checkpointed,
         checkpoint_decision: nil,
         checkpointed_attempts: Enum.uniq(record.checkpointed_attempts ++ [attempt])
     }}
  end

  defp apply_command(%{phase: :checkpointed} = record, {:checkpoint_update, _, _, value}, _),
    do: {:ok, %{record | checkpoint: value}}

  defp apply_command(%{phase: :checkpointed} = record, {:resume_checkpoint, _, _, value}, _),
    do:
      {:ok,
       %{
         record
         | checkpoint_decision: value,
           phase: :intended,
           checkpoint_grant_revision: record.revision + 1
       }}

  defp apply_command(record, {:reconcile, _, _, resolution, evidence}, _) do
    cond do
      not reconcilable?(record) ->
        {:error, :invalid_operation_state}

      resolution == :retry_permitted and not is_map(record.recovery) ->
        {:error, :recovery_unavailable}

      resolution == :retry_permitted ->
        {:ok, %{record | phase: :intended}}

      true ->
        class = if resolution == :confirmed_committed, do: :completed, else: :failed_known
        audit = %{operator_resolution: resolution, evidence: evidence}
        {:ok, %{record | phase: {:decided, class, audit, current_attempt(record)}}}
    end
  end

  defp apply_command(%{phase: :intended} = record, {:reject_intended, op, _, evidence}, state) do
    attempt = rejection_attempt(op)

    sequence(
      record,
      [{:attempt, op, attempt}, {:outcome, op, attempt, :rejected_before_dispatch, evidence}],
      state
    )
  end

  defp apply_command(
         record,
         {:retire_checkpoint, op, revision, decision, attempt, evidence},
         state
       ),
       do:
         sequence(
           record,
           [
             {:resume_checkpoint, op, revision, decision},
             {:attempt, op, attempt},
             {:outcome, op, attempt, :completed, evidence}
           ],
           state
         )

  defp apply_command(_, _, _), do: {:error, :invalid_operation_state}

  defp sequence(record, commands, state),
    do: Alto.Result.reduce(commands, record, &log_apply(&2, &1, state))

  defp append(state, command) do
    with {:ok, payload} <- Codec.encode(command, max_bytes: :erlang.external_size(command)),
         encoded <- JSON.encode!(payload),
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
