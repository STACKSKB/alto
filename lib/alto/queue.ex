defmodule Alto.Queue do
  @moduledoc """
  A durable, bounded claim/ack record queue (the integration contract, "durable queue").

  One GenServer per queue id, one append-only JSONL log per queue under the
  state home (`queues/<id>.jsonl`). Records travel as exact terms (base64
  `term_to_binary`, the `Alto.Session` convention), so a queued record
  survives restarts byte-exact; blanks and cancels persist as tombstones,
  so the default queue log is append-only like a session log. Hosts may opt
  into state compaction when historical entries are not an audit archive.

  Two key spaces share one log (the integration contract "Durable admission decision"):

  * **business keys** via `put/3` — idempotent upserts. A repeated key
    while pending updates its payload and bumps revision (record
    modification); while claimed it is an error; after blanking it
    legitimately re-queues as a new record. Redeliveries are the ingress's
    problem; the queue dedups by record key.
  * **delivery keys** via `admit/3` — insert-only source admission,
    first-wins. A repeated key while pending answers `:duplicate` without
    touching the stored bytes (even when the redelivered body differs);
    while claimed it answers `{:key_claimed, key}`; after blanking it
    answers `:duplicate` for as long as the key survives in the bounded
    completed window. The webhook `{:enqueue, _}` mode admits under
    `"endpoint-path:delivery-id"` keys, so admission dedups per source
    endpoint and completed markers survive ack and restart.

  `claim/3` hands out the oldest pending records under a lease. An
  expired lease reverts the record to pending lazily, so a crashed
  claimer loses its claim, never the record. Claims persist: a restart
  keeps claimed records under the same lease deadline. `claim_bounded/4`
  additionally budgets the encoded wire bytes, so a transport never leases
  records it cannot deliver; a lone oversized head answers
  `{:record_too_large, ...}` with nothing leased. `ack/2` blanks the
    record: removed from the queue, tombstoned in the log ("these records are
    processed"), and its key joins the completed window. `release/2` returns a
  claim to pending without completing. `cancel/2` blanks every record for
  a key (record cancellation) and completes the key.

  Bounds are part of correctness: record count,
  completed-window size, payload bytes, and key length all have explicit
  limits, and `put/4` rejects beyond them instead of truncating. Every
  mutation is appended and file-synced before it is acknowledged; creation
  and repair also flush the containing directory. A failed append leaves
  memory and disk in agreement and reports the error to the caller.
  A torn trailing write (crash mid-append) is discarded on replay; any
  other corruption fails the start loudly.
  """

  use GenServer

  alias Alto.Session, as: SessionStore
  alias Alto.DurableLog

  @version 6
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  @options [
    max_records: [type: :non_neg_integer, default: 10_000],
    max_completed: [type: :non_neg_integer, default: 10_000],
    max_payload_bytes: [type: :pos_integer, default: 64_000],
    max_key_bytes: [type: :pos_integer, default: 256],
    max_log_bytes: [type: :pos_integer, default: 64_000_000],
    lease_ms: [type: :pos_integer, default: 300_000],
    auto_compact: [type: :boolean, default: false],
    clock: [type: {:fun, 0}]
  ]
  @options_schema NimbleOptions.new!(@options)
  @max_claim_count 1_000
  @max_list_records 100

  @enforce_keys [:id, :dir, :path] ++ Keyword.keys(@options)
  defstruct @enforce_keys ++
              [
                :lock,
                records: :gb_trees.empty(),
                next_id: 1,
                completed: [],
                completed_set: MapSet.new()
              ]

  defmodule Record do
    @enforce_keys [:id, :key, :payload, :revision, :at_ms, :generation_id]
    defstruct [
      :id,
      :key,
      :payload,
      :revision,
      :at_ms,
      :generation_id,
      :operation_key,
      mode: :business,
      status: :pending,
      claim_id: nil,
      claimed_by: nil,
      lease_until_ms: nil,
      not_before_ms: nil
    ]
  end

  ## Client API

  @doc """
  Start a queue. Options:

    * `:id` — required queue id; names the storage file, validated like a
      session id so a hostile id cannot escape the queues directory;
    * `:dir` — storage directory (default: `<state home>/alto/queues`);
    * `:name` — registered process name (default `Alto.Queue`);
    * `:max_records` — pending + claimed record bound (default 10,000);
    * `:max_completed` — completed-delivery window bound (default 10,000
      keys; expiry re-admits, see `admit/3`);
    * `:max_payload_bytes` — per-record exact-term size bound (default 64,000);
    * `:max_key_bytes` — dedup key length bound (default 256);
    * `:max_log_bytes` — maximum replay file size (default 64 MiB);
    * `:auto_compact` — compact retained state before a full log rejects a write
      (default false; compaction replaces historical audit entries);
    * `:lease_ms` — claim lease (default 300,000);
    * `:clock` — injectable zero-arity millisecond clock (default system time);


  A corrupt log fails the start loudly, like `Alto.Session` — the queue
  never silently drops records it cannot decode. A torn trailing write
  (crash mid-append) is the exception: the partial tail is discarded and
  the file atomically replaced with the last acknowledged prefix.
  """
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    :ok = validate_id!(id)

    with {:ok, settings} <-
           NimbleOptions.validate(Keyword.take(opts, Keyword.keys(@options)), @options_schema) do
      directory = dir(opts)
      settings = Keyword.put_new(settings, :clock, fn -> System.system_time(:millisecond) end)

      state =
        struct!(__MODULE__, [id: id, dir: directory, path: log_path(directory, id)] ++ settings)

      Alto.Storage.start_server(__MODULE__, state, &load/1, opts)
    end
  end

  @doc "Storage directory for queue logs, honouring an explicit override."
  @spec dir(keyword()) :: Path.t()
  def dir(opts \\ []) do
    case Keyword.get(opts, :dir) do
      nil -> Path.join([Alto.Storage.state_home(), "alto", "queues"])
      path when is_binary(path) -> path
    end
  end

  @doc "Check a queue id for directory traversal and shape."
  @spec validate_id(term()) :: :ok | {:error, term()}
  def validate_id(id) when is_binary(id) do
    if Regex.match?(@id_pattern, id), do: :ok, else: {:error, {:invalid_queue_id, id}}
  end

  def validate_id(id), do: {:error, {:invalid_queue_id, id}}

  @doc """
  Idempotent upsert keyed by `key`. Pending records update in place
  (revision bumps); claimed keys reject; blanked keys re-queue fresh.

  This is the *business-key* path: last-arrival-wins by arrival order. It
  never consults the completed-delivery window — use `admit/3` for source
  delivery identity.
  Pass `delay_ms: non_neg_integer()` for relative scheduling or
  `not_before_ms: non_neg_integer()` for an absolute due time. The default
  is immediate eligibility.
  """
  @spec put(GenServer.server(), binary(), term(), keyword()) ::
          {:ok, %{id: String.t(), revision: pos_integer(), status: :pending}} | {:error, term()}
  def put(server \\ __MODULE__, key, payload, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:put, key, payload, opts})
  end

  @doc """
  Insert-only source admission keyed by `key` (callers pass a namespaced
  delivery key such as `"endpoint-path:delivery-id"`).

  First wins: a pending key answers `{:error, :duplicate}` without touching
  the stored bytes (even when the redelivered body differs); a claimed key
  answers `{:error, {:key_claimed, key}}`; a key blanked within the
  `max_completed` window answers `{:error, :duplicate}` without creating a
  second work item. Only a fresh key creates a record.
  Pass the same optional scheduling keys as `put/4`; duplicate admissions
  never modify the original schedule.
  """
  @spec admit(GenServer.server(), binary(), term(), keyword()) ::
          {:ok, %{id: String.t(), revision: pos_integer(), status: :pending}} | {:error, term()}
  def admit(server \\ __MODULE__, key, payload, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:admit, key, payload, opts})
  end

  @doc """
  Restore one operator-authorized recovery envelope under its original
  semantic operation identity. The derived recovery delivery key is
  insert-only, so repeating the same restore is harmless. An optional
  recovery_revision positive integer derives a distinct key for each later
  ledger-approved grant; ledger reconciliation remains a separate required
  authorization step.
  """
  @spec restore(GenServer.server(), binary(), binary(), map()) ::
          {:ok, %{id: String.t(), revision: pos_integer(), status: :pending}} | {:error, term()}
  def restore(server \\ __MODULE__, operation_key, generation_id, payload) do
    restore(server, operation_key, generation_id, payload, [])
  end

  @spec restore(GenServer.server(), binary(), binary(), map(), keyword()) ::
          {:ok, %{id: String.t(), revision: pos_integer(), status: :pending}} | {:error, term()}
  def restore(server, operation_key, generation_id, payload, opts) when is_list(opts) do
    GenServer.call(server, {:restore, operation_key, generation_id, payload, opts})
  end

  @doc "Claim up to `count` oldest pending records under a fresh lease."
  @spec claim(GenServer.server(), pos_integer(), term()) :: {:ok, [map()]}
  def claim(server \\ __MODULE__, count \\ 1, by \\ nil) when is_integer(count) and count >= 1 do
    GenServer.call(server, {:claim, min(count, @max_claim_count), by})
  end

  @doc """
  Atomically claim due records whose map payload contains every key/value in
  `selector`, preserving FIFO order among matching records. The selector is a
  non-empty map of at most eight UTF-8 string keys (1..100 bytes) and scalar
  values or flat lists of scalar values; its encoded term is bounded to 4 KiB.
  Matching scans the bounded queue globally, then applies the existing
  `max_bytes` wire budget and durable batch claim. Unrelated records remain
  pending. No selector is persisted and no executable predicate is accepted.
  """
  @spec claim_matching(GenServer.server(), map(), pos_integer(), term(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def claim_matching(server \\ __MODULE__, selector, count \\ 1, by \\ nil, max_bytes)
      when is_integer(count) and count >= 1 and is_integer(max_bytes) and max_bytes >= 0 do
    case validate_selector(selector) do
      :ok ->
        GenServer.call(
          server,
          {:claim_matching, selector, min(count, @max_claim_count), by, max_bytes}
        )

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Claim up to `count` oldest pending records whose encoded wire form fits
  in `max_bytes` (JSON array bytes of the claimed views).

  Records are selected oldest-first as a fitting prefix: claiming stops
  before the first record that would overflow the budget, so every leased
  record is deliverable. A lone oversized head answers
  `{:error, {:record_too_large, %{id: id, key: key, size: bytes}}}` with
  nothing leased — the record stays pending for an operator to inspect or
  cancel by key.
  """
  @spec claim_bounded(GenServer.server(), pos_integer(), term(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def claim_bounded(server \\ __MODULE__, count \\ 1, by \\ nil, max_bytes)
      when is_integer(count) and count >= 1 and is_integer(max_bytes) and max_bytes >= 0 do
    GenServer.call(server, {:claim_bounded, min(count, @max_claim_count), by, max_bytes})
  end

  @doc "Blank a claimed record (it was handled). The record is removed."
  @spec ack(GenServer.server(), String.t()) :: :ok | {:error, :not_found | :lease_expired}
  def ack(server \\ __MODULE__, claim_id) do
    GenServer.call(server, {:ack, claim_id})
  end

  @doc "Return a claim to pending (the client failed before finishing). Pass `delay_ms:` to delay it."
  @spec release(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def release(server \\ __MODULE__, claim_id, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:release, claim_id, opts})
  end

  @doc "Return a claim to pending after an optional delay, fenced by claim id."
  def reschedule(server \\ __MODULE__, claim_id, delay_ms)
      when is_integer(delay_ms) and delay_ms >= 0 do
    release(server, claim_id, delay_ms: delay_ms)
  end

  @doc "Blank every record for `key` (record cancellation)."
  @spec cancel(GenServer.server(), binary()) :: :ok | {:error, :not_found}
  def cancel(server \\ __MODULE__, key) do
    GenServer.call(server, {:cancel, key})
  end

  @doc "Cancel key only when every matching live record is pending."
  @spec cancel_pending(GenServer.server(), binary()) ::
          :ok | {:error, :not_found | {:key_claimed, binary()} | term()}
  def cancel_pending(server \\ __MODULE__, key) do
    GenServer.call(server, {:cancel_pending, key})
  end

  @doc "Pending and claimed counts."
  @spec count(GenServer.server()) :: %{pending: non_neg_integer(), claimed: non_neg_integer()}
  def count(server \\ __MODULE__) do
    GenServer.call(server, :count)
  end

  @doc "Bounded listing of live records, oldest first."
  @spec records(GenServer.server(), pos_integer()) :: [map()]
  def records(server \\ __MODULE__, max \\ @max_list_records) do
    GenServer.call(server, {:records, min(max, @max_list_records)})
  end

  @doc """
  Bounded snapshot of live records without lazy lease reclaim, oldest
  first (operator inspection). Unlike `records/2`, expired leases stay
  visible as claimed so stale owners read accurately; the snapshot never
  mutates queue state.
  """
  @spec snapshot(GenServer.server(), pos_integer()) :: [map()]
  def snapshot(server \\ __MODULE__, max \\ @max_list_records) do
    GenServer.call(server, {:snapshot, min(max, @max_list_records)})
  end

  @doc "Read one bounded live-record page without reclaiming leases."
  @spec snapshot_page(GenServer.server(), non_neg_integer(), pos_integer()) ::
          {:ok, %{records: [map()], next_cursor: non_neg_integer() | nil}} | {:error, term()}
  def snapshot_page(server \\ __MODULE__, cursor, limit \\ @max_list_records)
      when is_integer(cursor) and cursor >= 0 and is_integer(limit) and limit >= 1 do
    GenServer.call(server, {:snapshot_page, cursor, min(limit, @max_list_records)})
  end

  @doc "Find a live record by key without an oldest-page window."
  @spec lookup(GenServer.server(), binary()) :: {:ok, map()} | {:error, :not_found}
  def lookup(server \\ __MODULE__, key) when is_binary(key) do
    GenServer.call(server, {:lookup, key})
  end

  @doc """
  Replace historical log entries with the current queue and retained dedup keys.
  Keeps live claims, due times, record identity, ordering and the configured
  completed window unchanged. This is state retention, not an audit archive.
  Logs use one format for immediate, scheduled, and retained records.
  """
  def compact(server \\ __MODULE__), do: GenServer.call(server, :compact, :infinity)

  ## Server implementation

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  defp load(state) do
    with :ok <- DurableLog.open(state.dir, state.path), do: replay(state)
  end

  defp replay(state) do
    case DurableLog.replay(state.path, state.max_log_bytes, &replay_lines(state, &1)) do
      :missing -> {:ok, state}
      {:read_error, {:too_large, size, max}} -> {:error, {:queue_log_too_large, size, max}}
      {:read_error, reason} -> {:error, {:queue_read_failed, reason}}
      result -> result
    end
  end

  defp replay_lines(state, lines) do
    with :ok <- verify_retained_prefix(lines),
         {:ok, state} <- Alto.JSONLines.fold(state, lines, &apply_logged/3),
         do: {:ok, trim_completed(state)}
  end

  defp apply_logged(state, line, number) do
    case JSON.decode(line) do
      {:ok, %{"v" => @version, "type" => "retained_state"} = entry}
      when number == 1 ->
        restore_retained_state(state, entry)

      {:ok, %{"v" => version, "type" => type} = entry}
      when version == @version and is_binary(type) ->
        log_apply(state, type, entry)

      _other ->
        {:error, {:queue_corrupt, state.id, number}}
    end
  end

  # Replay applies logged transitions only; live ops only log transitions
  # they performed, so replaying reproduces the same state.
  defp log_apply(state, "record", entry) do
    with {:ok, record, sequence} <- decode_record(entry) do
      {:ok, %{put_record(state, record) | next_id: max(state.next_id, sequence + 1)}}
    end
  end

  defp log_apply(state, "lease", entry) do
    case {SessionStore.decode_term(entry["lease"]), fetch_record(state.records, entry["id"])} do
      {{:ok, {status, claim_id, by, until, due}}, {:ok, record}} ->
        next = %Record{
          record
          | status: status,
            claim_id: claim_id,
            claimed_by: by,
            lease_until_ms: until,
            not_before_ms: due
        }

        if valid_lease?(next) and validate_due(due) == :ok,
          do: {:ok, put_record(state, next)},
          else: {:error, :bad_entry}

      _ ->
        {:error, :bad_entry}
    end
  end

  defp log_apply(state, "blank", entry) do
    case fetch_record(state.records, entry["id"]) do
      {:ok, record} ->
        {:ok, state |> drop_record(entry["id"]) |> track_completed(record.key)}

      :error ->
        {:ok, state}
    end
  end

  defp log_apply(_state, _type, _entry), do: {:error, :bad_entry}

  defp decode_record(%{"record" => encoded}) do
    with {:ok, %Record{} = record} <- SessionStore.decode_term(encoded),
         true <- Enum.sort(Map.keys(record)) == Enum.sort(Map.keys(Record.__struct__())),
         true <- is_binary(record.key) and is_integer(record.revision) and record.revision >= 1,
         true <- record.mode in [:business, :delivery, :recovery] and is_integer(record.at_ms),
         true <- valid_lease?(record),
         {:ok, sequence} <- record_sequence(record.id),
         :ok <- validate_generation(record.generation_id),
         :ok <- validate_due(record.not_before_ms) do
      {:ok, record, sequence}
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_entry}
    end
  end

  defp decode_record(_), do: {:error, :bad_entry}

  defp valid_lease?(%Record{
         status: :pending,
         claim_id: nil,
         claimed_by: nil,
         lease_until_ms: nil
       }),
       do: true

  defp valid_lease?(%Record{status: :claimed, claim_id: id, lease_until_ms: until}),
    do: is_binary(id) and is_integer(until)

  defp valid_lease?(_), do: false

  @impl true
  def handle_call({operation, key, payload, opts}, _from, state)
      when operation in [:put, :admit] do
    current = reclaim_expired(state)
    mode = if operation == :put, do: :business, else: :delivery

    with :ok <- validate_key(key, current),
         :ok <- validate_payload(payload, current),
         {:ok, due} <- schedule_at(current, opts),
         {:ok, record} <- build_record(current, key, payload, mode, not_before_ms: due) do
      commit_record(state, current, record)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:restore, operation_key, generation_id, payload, opts}, _from, state) do
    current = reclaim_expired(state)

    with :ok <- validate_key(operation_key, current),
         :ok <- validate_generation(generation_id),
         :ok <- validate_payload(payload, current),
         {:ok, revision} <- recovery_revision(opts),
         {:ok, record} <-
           build_record(current, recovery_key(operation_key, revision), payload, :recovery,
             generation_id: generation_id,
             operation_key: operation_key
           ) do
      commit_record(state, current, record)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:claim, count, by}, _from, state) do
    do_claim(state, count, by, :infinity, %{})
  end

  @impl true
  def handle_call({:claim_bounded, count, by, max_bytes}, _from, state) do
    do_claim(state, count, by, max_bytes, %{})
  end

  def handle_call({:claim_matching, selector, count, by, max_bytes}, _from, state) do
    do_claim(state, count, by, max_bytes, selector)
  end

  def handle_call({:ack, claim_id}, from, state),
    do: handle_call({:settle, claim_id, :ack, []}, from, state)

  def handle_call({:release, claim_id, opts}, from, state),
    do: handle_call({:settle, claim_id, :release, opts}, from, state)

  def handle_call({:settle, claim_id, operation, opts}, _from, state) do
    with {:ok, record} <- find_by_claim(state, claim_id),
         true <- record.lease_until_ms > now(state) or {:error, :lease_expired},
         {:ok, due} <- schedule_at(state, opts) do
      log =
        case operation do
          :ack -> %{"type" => "blank", "reason" => "acked"}
          :release -> lease_log(%Record{unclaim(record) | not_before_ms: due})
        end

      log = Map.merge(log, %{"v" => @version, "id" => record.id})
      commit(state, state, [log], :ok, true)
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, :lease_expired} -> {:reply, {:error, :lease_expired}, reclaim_expired(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({operation, key}, _from, state)
      when operation in [:cancel, :cancel_pending] do
    victims =
      ordered_records(state)
      |> Enum.filter(&(&1.key == key))

    if operation == :cancel_pending and Enum.any?(victims, &(&1.status == :claimed)) do
      {:reply, {:error, {:key_claimed, key}}, state}
    else
      cancel_records(state, victims)
    end
  end

  def handle_call(:compact, _from, state) do
    {:reply, compact_log(state, 0), state}
  end

  def handle_call(:count, _from, state) do
    counts =
      ordered_records(state)
      |> Enum.frequencies_by(& &1.status)

    {:reply, %{pending: Map.get(counts, :pending, 0), claimed: Map.get(counts, :claimed, 0)},
     state}
  end

  def handle_call({operation, max}, _from, state) when operation in [:records, :snapshot] do
    state = if operation == :records, do: reclaim_expired(state), else: state
    views = state |> ordered_records() |> Enum.take(max) |> Enum.map(&view/1)
    {:reply, views, state}
  end

  def handle_call({:snapshot_page, cursor, limit}, _from, state) do
    records =
      ordered_records(state)
      |> Enum.slice(cursor, limit)
      |> Enum.map(&view/1)

    next_cursor =
      if cursor + length(records) < :gb_trees.size(state.records),
        do: cursor + length(records),
        else: nil

    {:reply, {:ok, %{records: records, next_cursor: next_cursor}}, state}
  end

  def handle_call({:lookup, key}, _from, state) do
    reply =
      case find_by_key(state, key) do
        nil -> {:error, :not_found}
        record -> {:ok, view(record)}
      end

    {:reply, reply, state}
  end

  defp cancel_records(state, []) do
    {:reply, {:error, :not_found}, state}
  end

  defp cancel_records(state, victims) do
    logs =
      Enum.map(victims, fn record ->
        %{"v" => @version, "type" => "blank", "id" => record.id, "reason" => "cancelled"}
      end)

    commit(state, state, logs, :ok, true)
  end

  # Completed-delivery window: newest-first, unique, bounded. Expiry is
  # honest re-admission — a redelivery past eviction legitimately re-queues.
  defp track_completed(state, key) do
    completed =
      [key | List.delete(state.completed, key)]
      |> Enum.take(max(state.max_completed, 0))

    %{state | completed: completed, completed_set: MapSet.new(completed)}
  end

  defp trim_completed(state) do
    completed = Enum.take(state.completed, max(state.max_completed, 0))
    %{state | completed: completed, completed_set: MapSet.new(completed)}
  end

  # Claim ids are persisted in the log and presented back by clients across
  # restarts, so they must not come from BEAM-lifetime uniqueness.
  defp fresh_claim_id do
    "clm-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp do_claim(state, count, by, budget, selector) do
    state = reclaim_expired(state)

    now = now(state)

    pending =
      ordered_records(state)
      |> Enum.filter(
        &(&1.status == :pending and due?(&1, now) and matches_selector?(&1, selector))
      )
      |> Enum.take(count)

    candidates =
      Enum.map(pending, fn record ->
        %Record{
          record
          | status: :claimed,
            claim_id: fresh_claim_id(),
            claimed_by: by,
            lease_until_ms: now + state.lease_ms
        }
      end)

    case select_fitting(candidates, budget) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, []} ->
        {:reply, {:ok, []}, state}

      {:ok, claimed} ->
        logs = Enum.map(claimed, &lease_log/1)

        commit(state, state, logs, {:ok, Enum.map(claimed, &view/1)}, true)
    end
  end

  defp matches_selector?(_record, selector) when map_size(selector) == 0, do: true

  defp matches_selector?(%Record{payload: payload}, selector) when is_map(payload) do
    Enum.all?(selector, fn {key, value} -> Map.get(payload, key, :__missing__) === value end)
  end

  defp validate_selector(selector) when is_map(selector) and map_size(selector) in 1..8 do
    valid? =
      byte_size(:erlang.term_to_binary(selector)) <= 4_096 and
        Enum.all?(selector, fn {key, value} ->
          is_binary(key) and byte_size(key) in 1..100 and String.valid?(key) and
            selector_value?(value)
        end)

    if valid?, do: :ok, else: {:error, :invalid_selector}
  end

  defp validate_selector(_), do: {:error, :invalid_selector}

  defp selector_value?(nil), do: true
  defp selector_value?(value) when is_boolean(value), do: true
  defp selector_value?(value) when is_integer(value), do: true
  defp selector_value?(value) when is_float(value), do: true
  defp selector_value?(value) when is_binary(value), do: String.valid?(value)
  defp selector_value?(value) when is_list(value), do: Enum.all?(value, &selector_scalar?/1)
  defp selector_value?(_), do: false

  defp selector_scalar?(value), do: not is_list(value) and selector_value?(value)

  # Oldest-first fitting prefix over the encoded wire form, so every leased
  # record is deliverable and an encoding failure never strands a lease.
  defp select_fitting(records, :infinity), do: {:ok, records}

  defp select_fitting(records, budget) when is_integer(budget),
    do: fitting_prefix(records, budget - 2, [])

  # Reserve array brackets up front and the next separator after each record.
  defp fitting_prefix([], _remaining, kept), do: {:ok, Enum.reverse(kept)}

  defp fitting_prefix([record | rest], remaining, kept) do
    case wire_size(record) do
      {:ok, size} when size <= remaining ->
        fitting_prefix(rest, remaining - size - 1, [record | kept])

      {:ok, size} when kept == [] ->
        {:error, {:record_too_large, %{id: record.id, key: record.key, size: size}}}

      {:ok, _size} ->
        {:ok, Enum.reverse(kept)}

      {:error, _reason} ->
        {:error, {:queue_unencodable, record.id}}
    end
  end

  # The same codec the transports use: lossy term encoding, then JSON.
  defp wire_size(record) do
    size =
      record
      |> view()
      |> Alto.Protocol.encode_term()
      |> JSON.encode!()
      |> byte_size()

    {:ok, size}
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Expired leases revert lazily: no timer, no scheduler — a claim dies
  # when someone looks, and the log keeps the last transition per record.
  defp reclaim_expired(state) do
    now = now(state)

    Enum.reduce(ordered_records(state), state, fn
      %Record{status: :claimed, lease_until_ms: until} = record, state
      when is_integer(until) and until <= now ->
        put_record(state, unclaim(record))

      _record, state ->
        state
    end)
  end

  defp unclaim(record),
    do: %Record{record | status: :pending, claim_id: nil, claimed_by: nil, lease_until_ms: nil}

  defp now(state), do: state.clock.()

  defp due?(%Record{not_before_ms: nil}, _now), do: true
  defp due?(%Record{not_before_ms: at}, now) when is_integer(at), do: at <= now

  defp schedule_at(state, opts) do
    if Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == MapSet.size(MapSet.new(Keyword.keys(opts))) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:not_before_ms, :delay_ms])) do
      case {Keyword.get(opts, :not_before_ms), Keyword.get(opts, :delay_ms)} do
        {nil, nil} -> {:ok, nil}
        {at, nil} when is_integer(at) and at >= 0 -> {:ok, at}
        {nil, delay} when is_integer(delay) and delay >= 0 -> {:ok, now(state) + delay}
        _ -> {:error, {:invalid_schedule, opts}}
      end
    else
      {:error, {:invalid_schedule, opts}}
    end
  end

  defp validate_due(nil), do: :ok
  defp validate_due(at) when is_integer(at) and at >= 0, do: :ok
  defp validate_due(_at), do: {:error, :bad_entry}

  defp validate_key(key, state) when is_binary(key) do
    if byte_size(key) in 1..state.max_key_bytes, do: :ok, else: {:error, {:invalid_key, key}}
  end

  defp validate_key(key, _state), do: {:error, {:invalid_key, key}}

  defp validate_payload(payload, state) when is_map(payload) do
    size = byte_size(:erlang.term_to_binary(payload))

    if size <= state.max_payload_bytes do
      :ok
    else
      {:error, {:payload_too_large, size}}
    end
  end

  defp validate_payload(payload, _state), do: {:error, {:invalid_payload, payload}}

  defp validate_room(state) do
    if :gb_trees.size(state.records) < state.max_records,
      do: :ok,
      else: {:error, :queue_full}
  end

  defp build_record(state, key, payload, mode, fields) do
    existing = find_by_key(state, key)

    cond do
      mode != :business and MapSet.member?(state.completed_set, key) ->
        {:error, :duplicate}

      existing && existing.status == :claimed ->
        {:error, {:key_claimed, key}}

      existing && mode != :business ->
        {:error, :duplicate}

      existing ->
        {:ok,
         %{
           existing
           | payload: payload,
             revision: existing.revision + 1,
             not_before_ms: fields[:not_before_ms]
         }}

      true ->
        with :ok <- validate_room(state) do
          {:ok,
           %Record{
             id: "rec-#{state.next_id}",
             key: key,
             payload: payload,
             revision: 1,
             at_ms: now(state),
             mode: mode,
             generation_id: fields[:generation_id] || generate_generation_id(),
             operation_key: fields[:operation_key],
             not_before_ms: fields[:not_before_ms]
           }}
        end
    end
  end

  defp put_log(record),
    do: %{"v" => @version, "type" => "record", "record" => SessionStore.encode_term(record)}

  defp lease_log(record) do
    lease =
      {record.status, record.claim_id, record.claimed_by, record.lease_until_ms,
       record.not_before_ms}

    %{
      "v" => @version,
      "type" => "lease",
      "id" => record.id,
      "lease" => SessionStore.encode_term(lease)
    }
  end

  defp commit_record(original, current, record) do
    reply = {:ok, Map.take(record, [:id, :revision, :status])}
    commit(original, current, [put_log(record)], reply)
  end

  # Live commands and restart replay apply the same records. Publish state only
  # after the complete mutation has been durably appended.
  defp commit(original, current, records, reply, wrap_error \\ false) do
    with {:ok, next} <-
           Alto.Result.reduce(records, current, fn record, acc ->
             log_apply(acc, record["type"], record)
           end),
         :ok <- append(current, records) do
      {:reply, reply, next}
    else
      {:error, reason} ->
        reason = if wrap_error, do: {:queue_write_failed, reason}, else: reason
        {:reply, {:error, reason}, original}
    end
  end

  defp find_by_claim(state, claim_id) do
    Enum.find_value(ordered_records(state), fn record ->
      if record.claim_id == claim_id, do: {:ok, record}
    end)
    |> case do
      nil -> :error
      found -> found
    end
  end

  defp find_by_key(state, key),
    do: Enum.find(ordered_records(state), &(&1.key == key))

  defp view(%Record{} = record) do
    {mode, fields} = Map.pop(Map.from_struct(record), :mode)

    fields
    |> Map.put(:admission, mode)
    |> Map.put(:operation_key, operation_key(record))
  end

  defp operation_key(%Record{operation_key: key}) when is_binary(key), do: key
  defp operation_key(%Record{mode: :delivery, key: key}), do: key
  defp operation_key(%Record{generation_id: id}), do: "business-generation:" <> id

  defp generate_generation_id do
    "gen-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp validate_generation(id) when is_binary(id) and byte_size(id) in 1..256, do: :ok
  defp validate_generation(id), do: {:error, {:invalid_generation_id, id}}

  defp recovery_key(operation_key, revision) do
    material =
      if revision == nil,
        do: operation_key,
        else: :erlang.term_to_binary({operation_key, revision}, [:deterministic])

    "recovery-" <> (:crypto.hash(:sha256, material) |> Base.url_encode64(padding: false))
  end

  defp recovery_revision([]), do: {:ok, nil}
  defp recovery_revision(recovery_revision: nil), do: {:ok, nil}

  defp recovery_revision(recovery_revision: revision)
       when is_integer(revision) and revision > 0,
       do: {:ok, revision}

  defp recovery_revision(recovery_revision: other),
    do: {:error, {:invalid_recovery_revision, other}}

  defp recovery_revision(opts), do: {:error, {:invalid_recovery_revision, opts}}

  defp put_record(state, %Record{} = record) do
    {:ok, sequence} = record_sequence(record.id)
    %{state | records: :gb_trees.enter(sequence, record, state.records)}
  end

  defp ordered_records(state), do: :gb_trees.values(state.records)

  defp drop_record(state, id) do
    case record_sequence(id) do
      {:ok, sequence} -> %{state | records: :gb_trees.delete_any(sequence, state.records)}
      :error -> state
    end
  end

  defp fetch_record(records, id) do
    with {:ok, sequence} <- record_sequence(id),
         {:value, record} <- :gb_trees.lookup(sequence, records) do
      {:ok, record}
    else
      _ -> :error
    end
  end

  defp record_sequence("rec-" <> digits) do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, digits),
      do: {:ok, String.to_integer(digits)},
      else: :error
  end

  defp record_sequence(_id), do: :error

  # One append per mutation, file-synced before acknowledgement. A failed
  # write leaves state untouched: memory and disk stay in agreement.
  defp append(state, log_or_logs) do
    logs = if is_list(log_or_logs), do: log_or_logs, else: [log_or_logs]

    lines =
      logs
      |> Enum.map(&JSON.encode!/1)
      |> Enum.intersperse("\n")
      |> Kernel.++(["\n"])

    bytes = IO.iodata_length(lines)

    with :ok <- ensure_log_room(state, bytes),
         :ok <- DurableLog.append(state.path, lines) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:queue_unencodable, Exception.message(error)}}
  end

  defp ensure_log_room(state, append_bytes) do
    case File.stat(state.path) do
      {:ok, %{size: current}} when current + append_bytes <= state.max_log_bytes ->
        :ok

      {:ok, %{size: current}} ->
        if state.auto_compact do
          case compact_log(state, append_bytes) do
            {:ok, _} -> :ok
            error -> error
          end
        else
          {:error, {:queue_log_too_large, current + append_bytes, state.max_log_bytes}}
        end

      {:error, reason} ->
        {:error, {:queue_write_failed, reason}}
    end
  end

  # Replacement contains only already-held state. The requested mutation is
  # appended afterwards through the existing sync path; a replacement failure
  # cannot commit an operation that its caller was told had failed.
  defp compact_log(state, reserved_bytes) do
    retained = Enum.map(ordered_records(state), &put_log/1)
    record_lines = Enum.map(retained, &JSON.encode!/1)

    header = %{
      "v" => @version,
      "type" => "retained_state",
      "queue" => state.id,
      "next_id" => state.next_id,
      "completed" => state.completed,
      "entries" => length(record_lines),
      "sha256" => retained_digest(record_lines)
    }

    lines = [JSON.encode!(header), "\n", Alto.JSONLines.join(record_lines)]
    bytes = IO.iodata_length(lines)

    with true <-
           bytes + reserved_bytes <= state.max_log_bytes or
             {:error, {:queue_log_too_large, bytes + reserved_bytes, state.max_log_bytes}},
         {:ok, %{size: before}} <- File.stat(state.path),
         :ok <- DurableLog.replace(state.path, lines) do
      {:ok,
       %{
         before_bytes: before,
         after_bytes: bytes,
         live_records: :gb_trees.size(state.records),
         completed_keys: length(state.completed)
       }}
    else
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, {:queue_compaction_failed, Exception.message(error)}}
  end

  # Canonical records were synced before replacement, so a missing record is
  # corruption, not an interrupted append. Only a tail after the complete
  # retained prefix can use ordinary torn-append recovery.
  defp verify_retained_prefix([]), do: :ok

  defp verify_retained_prefix([header | rest]) do
    case JSON.decode(header) do
      {:ok,
       %{
         "v" => @version,
         "type" => "retained_state",
         "entries" => count,
         "sha256" => digest
       }}
      when is_integer(count) and count >= 0 and is_binary(digest) ->
        records = Enum.take(rest, count)

        if length(records) == count and retained_digest(records) == digest,
          do: :ok,
          else: {:error, :invalid_retained_queue_prefix}

      {:ok, %{"type" => "retained_state"}} ->
        {:error, :invalid_retained_queue_prefix}

      _ ->
        :ok
    end
  end

  defp retained_digest(lines),
    do: :crypto.hash(:sha256, Alto.JSONLines.join(lines)) |> Base.encode16(case: :lower)

  defp restore_retained_state(
         state,
         %{
           "v" => @version,
           "type" => "retained_state",
           "queue" => queue,
           "next_id" => next_id,
           "completed" => completed
         } = entry
       )
       when map_size(entry) == 7 and is_integer(next_id) and next_id >= 1 and is_list(completed) do
    if queue == state.id and Enum.all?(completed, &(validate_key(&1, state) == :ok)) and
         length(completed) == MapSet.size(MapSet.new(completed)) do
      {:ok, trim_completed(%{state | next_id: next_id, completed: completed})}
    else
      {:error, :bad_entry}
    end
  end

  defp restore_retained_state(_, _), do: {:error, :bad_entry}

  defp log_path(dir, id), do: Path.join(dir, id <> ".jsonl")

  defp validate_id!(id) do
    case validate_id(id) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid queue id: #{inspect(reason)}"
    end
  end
end
