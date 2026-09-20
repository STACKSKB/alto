defmodule Alto.Queue do
  @moduledoc """
  A durable, bounded claim/ack record queue (the integration contract, "durable queue").

  One GenServer per queue id, one append-only JSONL log per queue under the
  state home (`queues/<id>.jsonl`). Payloads travel as exact terms (base64
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

  @version 4
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  @default_max_records 10_000
  @default_max_completed 10_000
  @default_max_payload_bytes 64_000
  @default_max_key_bytes 256
  @default_max_log_bytes 64_000_000
  @default_lease_ms 300_000
  @max_claim_count 1_000
  @max_list_records 100

  @enforce_keys [
    :id,
    :dir,
    :path,
    :max_records,
    :max_completed,
    :max_payload_bytes,
    :max_key_bytes,
    :max_log_bytes,
    :lease_ms,
    :clock
  ]
  defstruct [
    :id,
    :dir,
    :path,
    :lock,
    :max_records,
    :max_completed,
    :max_payload_bytes,
    :max_key_bytes,
    :max_log_bytes,
    :lease_ms,
    :clock,
    auto_compact: false,
    records: %{},
    fifo: [],
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

    dir = Keyword.get(opts, :dir, dir(opts))

    max_completed = Keyword.get(opts, :max_completed, @default_max_completed)

    clock = Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end)

    auto_compact = Keyword.get(opts, :auto_compact, false)

    with :ok <- validate_auto_compact(auto_compact),
         :ok <- validate_max_completed(max_completed),
         :ok <- validate_clock(clock) do
      state = %__MODULE__{
        id: id,
        dir: dir,
        path: log_path(dir, id),
        max_records: Keyword.get(opts, :max_records, @default_max_records),
        max_completed: max_completed,
        auto_compact: auto_compact,
        max_payload_bytes: Keyword.get(opts, :max_payload_bytes, @default_max_payload_bytes),
        max_key_bytes: Keyword.get(opts, :max_key_bytes, @default_max_key_bytes),
        max_log_bytes: Keyword.get(opts, :max_log_bytes, @default_max_log_bytes),
        lease_ms: Keyword.get(opts, :lease_ms, @default_lease_ms),
        clock: clock
      }

      case Alto.Storage.acquire(state.path <> ".lock",
             timeout: Keyword.get(opts, :lock_timeout, 5_000)
           ) do
        {:ok, lock} ->
          # Replay happens before the process exists, while the lifetime lock
          # prevents another VM from loading a stale snapshot concurrently.
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

  defp validate_auto_compact(value) when is_boolean(value), do: :ok
  defp validate_auto_compact(value), do: {:error, {:invalid_auto_compact, value}}

  defp validate_max_completed(n) when is_integer(n) and n >= 0, do: :ok
  defp validate_max_completed(n), do: {:error, {:invalid_max_completed, n}}

  defp validate_clock(clock) when is_function(clock, 0), do: :ok
  defp validate_clock(clock), do: {:error, {:invalid_clock, clock}}

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
  defp log_apply(state, "put", entry) do
    with {:ok, record} <- decode_record(entry) do
      "rec-" <> digits = record.id

      {:ok,
       %{put_record(state, record) | next_id: max(state.next_id, String.to_integer(digits) + 1)}}
    end
  end

  defp log_apply(state, "claim", entry) do
    with {:ok, owner} <- SessionStore.decode_term(entry["by"]) do
      case Map.fetch(state.records, entry["id"]) do
        {:ok, record} ->
          record = %Record{
            record
            | status: :claimed,
              claim_id: entry["claim_id"],
              claimed_by: owner,
              lease_until_ms: entry["until_ms"]
          }

          {:ok, put_record(state, record)}

        :error ->
          {:ok, state}
      end
    end
  end

  defp log_apply(state, "release", entry) do
    with :ok <- validate_due(entry["not_before_ms"]) do
      case Map.fetch(state.records, entry["id"]) do
        {:ok, record} ->
          {:ok,
           put_record(state, %Record{unclaim(record) | not_before_ms: entry["not_before_ms"]})}

        :error ->
          {:ok, state}
      end
    end
  end

  defp log_apply(state, "blank", entry) do
    case Map.fetch(state.records, entry["id"]) do
      {:ok, record} ->
        {:ok, state |> drop_record(entry["id"]) |> track_completed(record.key)}

      :error ->
        {:ok, state}
    end
  end

  defp log_apply(_state, _type, _entry), do: {:error, :bad_entry}

  defp decode_record(
         %{
           "id" => id,
           "key" => key,
           "payload" => encoded,
           "revision" => revision,
           "mode" => mode,
           "generation_id" => generation,
           "at_ms" => at
         } = entry
       )
       when is_binary(id) and is_binary(key) and is_integer(revision) and revision >= 1 and
              mode in ["business", "delivery", "recovery"] and is_integer(at) do
    with true <- Regex.match?(~r/\Arec-[1-9][0-9]*\z/, id) or {:error, :bad_entry},
         :ok <- validate_generation(generation),
         :ok <- validate_due(entry["not_before_ms"]),
         {:ok, payload} <- SessionStore.decode_term(encoded) do
      {:ok,
       %Record{
         id: id,
         key: key,
         payload: payload,
         revision: revision,
         at_ms: at,
         mode: String.to_existing_atom(mode),
         generation_id: generation,
         operation_key: entry["operation_key"],
         not_before_ms: entry["not_before_ms"]
       }}
    end
  end

  defp decode_record(_), do: {:error, :bad_entry}

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
          :release -> %{"type" => "release", "not_before_ms" => due}
        end

      log = Map.merge(log, %{"v" => @version, "id" => record.id})
      commit(state, state, [log], :ok, true)
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, :lease_expired} -> {:reply, {:error, :lease_expired}, reclaim_expired(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, key}, _from, state) do
    victims =
      state.records
      |> Map.values()
      |> Enum.filter(&(&1.key == key))

    cancel_records(state, key, victims)
  end

  def handle_call({:cancel_pending, key}, _from, state) do
    victims =
      state.records
      |> Map.values()
      |> Enum.filter(&(&1.key == key))

    cond do
      victims == [] ->
        {:reply, {:error, :not_found}, state}

      Enum.any?(victims, &(&1.status == :claimed)) ->
        {:reply, {:error, {:key_claimed, key}}, state}

      true ->
        cancel_records(state, key, victims)
    end
  end

  def handle_call(:compact, _from, state) do
    {:reply, compact_log(state, 0), state}
  end

  def handle_call(:count, _from, state) do
    counts =
      state.records
      |> Map.values()
      |> Enum.frequencies_by(& &1.status)

    {:reply, %{pending: Map.get(counts, :pending, 0), claimed: Map.get(counts, :claimed, 0)},
     state}
  end

  def handle_call({:records, max}, _from, state) do
    state = reclaim_expired(state)

    views =
      state.fifo
      |> Enum.take(max)
      |> Enum.map(&Map.fetch!(state.records, &1))
      |> Enum.map(&view/1)

    {:reply, views, state}
  end

  def handle_call({:snapshot, max}, _from, state) do
    views =
      state.fifo
      |> Enum.take(max)
      |> Enum.map(&Map.fetch!(state.records, &1))
      |> Enum.map(&view/1)

    {:reply, views, state}
  end

  def handle_call({:snapshot_page, cursor, limit}, _from, state) do
    records =
      state.fifo
      |> Enum.slice(cursor, limit)
      |> Enum.map(&Map.fetch!(state.records, &1))
      |> Enum.map(&view/1)

    next_cursor =
      if cursor + length(records) < length(state.fifo),
        do: cursor + length(records),
        else: nil

    {:reply, {:ok, %{records: records, next_cursor: next_cursor}}, state}
  end

  def handle_call({:lookup, key}, _from, state) do
    result =
      Enum.find_value(state.fifo, fn id ->
        record = Map.fetch!(state.records, id)
        if record.key == key, do: view(record)
      end)

    reply = if result, do: {:ok, result}, else: {:error, :not_found}
    {:reply, reply, state}
  end

  defp cancel_records(state, _key, []) do
    {:reply, {:error, :not_found}, state}
  end

  defp cancel_records(state, _key, victims) do
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
      state.fifo
      |> Enum.map(&Map.fetch!(state.records, &1))
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
        logs = Enum.map(claimed, &Map.put(claim_log(&1), "at_ms", now))

        commit(state, state, logs, {:ok, Enum.map(claimed, &view/1)}, true)
    end
  end

  defp matches_selector?(_record, selector) when map_size(selector) == 0, do: true

  defp matches_selector?(%Record{payload: payload}, selector) when is_map(payload) do
    Enum.all?(selector, fn {key, value} -> Map.get(payload, key, :__missing__) === value end)
  end

  defp validate_selector(selector) when is_map(selector) and map_size(selector) in 1..8 do
    with :ok <- validate_selector_bytes(selector),
         :ok <- validate_selector_keys(selector),
         :ok <- validate_selector_values(selector) do
      :ok
    end
  end

  defp validate_selector(_), do: {:error, :invalid_selector}

  defp validate_selector_keys(selector) do
    if Enum.all?(
         Map.keys(selector),
         &(is_binary(&1) and String.valid?(&1) and byte_size(&1) in 1..100)
       ),
       do: :ok,
       else: {:error, :invalid_selector}
  end

  defp validate_selector_values(selector) do
    if Enum.all?(Map.values(selector), &selector_value?/1),
      do: :ok,
      else: {:error, :invalid_selector}
  end

  defp selector_value?(nil), do: true
  defp selector_value?(value) when is_boolean(value), do: true
  defp selector_value?(value) when is_integer(value), do: true
  defp selector_value?(value) when is_float(value), do: true
  defp selector_value?(value) when is_binary(value), do: String.valid?(value)
  defp selector_value?(value) when is_list(value), do: Enum.all?(value, &selector_scalar?/1)
  defp selector_value?(_), do: false

  defp selector_scalar?(value), do: not is_list(value) and selector_value?(value)

  defp validate_selector_bytes(selector) do
    if byte_size(:erlang.term_to_binary(selector)) <= 4_096,
      do: :ok,
      else: {:error, :invalid_selector}
  rescue
    _ -> {:error, :invalid_selector}
  end

  # Oldest-first fitting prefix over the encoded wire form, so every leased
  # record is deliverable and an encoding failure never strands a lease.
  defp select_fitting(records, :infinity), do: {:ok, records}

  defp select_fitting([], _budget), do: {:ok, []}

  defp select_fitting([head | _] = records, budget) when is_integer(budget) do
    case wire_sizes(records) do
      {:ok, sizes} -> fitting_prefix(records, sizes, budget)
      {:error, _reason} -> {:error, {:queue_unencodable, head.id}}
    end
  end

  defp wire_sizes(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, sizes} ->
      case wire_size(record) do
        {:ok, size} -> {:cont, {:ok, [size | sizes]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, sizes} -> {:ok, Enum.reverse(sizes)}
      {:error, reason} -> {:error, reason}
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

  # Encoded JSON-array bytes of the claimed views: brackets plus commas.
  defp fitting_prefix(records, sizes, budget) do
    {fitting, _} =
      Enum.zip(records, sizes)
      |> Enum.reduce_while({[], 2}, fn {record, size}, {kept, total} ->
        total = total + size + if(kept == [], do: 0, else: 1)

        if total <= budget do
          {:cont, {[record | kept], total}}
        else
          {:halt, {kept, total}}
        end
      end)

    case Enum.reverse(fitting) do
      [] ->
        [head | _] = records
        [size | _] = sizes
        {:error, {:record_too_large, %{id: head.id, key: head.key, size: size}}}

      fitting ->
        {:ok, fitting}
    end
  end

  # Expired leases revert lazily: no timer, no scheduler — a claim dies
  # when someone looks, and the log keeps the last transition per record.
  defp reclaim_expired(state) do
    now = now(state)

    Enum.reduce(state.records, state, fn
      {_id, %Record{status: :claimed, lease_until_ms: until} = record}, state
      when is_integer(until) and until <= now ->
        put_record(state, unclaim(record))

      {_id, _record}, state ->
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
    if map_size(state.records) < state.max_records, do: :ok, else: {:error, :queue_full}
  end

  defp build_record(state, key, payload, mode, fields) do
    existing =
      Enum.find_value(state.records, fn {_id, record} ->
        if record.key == key, do: record
      end)

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

  defp put_log(record) do
    record
    |> Map.from_struct()
    |> Map.take([
      :id,
      :key,
      :payload,
      :revision,
      :mode,
      :generation_id,
      :operation_key,
      :not_before_ms,
      :at_ms
    ])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("payload", SessionStore.encode_term(record.payload))
    |> Map.put("mode", Atom.to_string(record.mode))
    |> Map.merge(%{"v" => @version, "type" => "put"})
  end

  defp commit_record(original, current, record) do
    reply = {:ok, Map.take(record, [:id, :revision, :status])}
    commit(original, current, [put_log(record)], reply)
  end

  # Live commands and restart replay apply the same records. Publish state only
  # after the complete mutation has been durably appended.
  defp commit(original, current, records, reply, wrap_error \\ false) do
    with {:ok, next} <-
           Enum.reduce_while(records, {:ok, current}, fn record, {:ok, acc} ->
             case log_apply(acc, record["type"], record) do
               {:ok, next} -> {:cont, {:ok, next}}
               error -> {:halt, error}
             end
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
    Enum.find_value(state.records, fn {_id, record} ->
      if record.claim_id == claim_id, do: {:ok, record}
    end)
    |> case do
      nil -> :error
      found -> found
    end
  end

  defp view(%Record{} = record) do
    %{
      id: record.id,
      key: record.key,
      payload: record.payload,
      revision: record.revision,
      status: record.status,
      at_ms: record.at_ms,
      claim_id: record.claim_id,
      claimed_by: record.claimed_by,
      lease_until_ms: record.lease_until_ms,
      not_before_ms: record.not_before_ms,
      generation_id: record.generation_id,
      operation_key: record.operation_key,
      admission: record.mode
    }
  end

  defp generate_generation_id do
    "gen-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp validate_generation(id) when is_binary(id) and byte_size(id) in 1..256, do: :ok
  defp validate_generation(id), do: {:error, {:invalid_generation_id, id}}

  defp recovery_key(operation_key, nil) do
    digest = :crypto.hash(:sha256, operation_key) |> Base.url_encode64(padding: false)
    "recovery-" <> digest
  end

  defp recovery_key(operation_key, revision) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({operation_key, revision}, [:deterministic]))
      |> Base.url_encode64(padding: false)

    "recovery-" <> digest
  end

  defp recovery_revision(opts) do
    if Keyword.keyword?(opts) and
         Keyword.keys(opts) |> Enum.uniq() == Keyword.keys(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 == :recovery_revision)) do
      case Keyword.get(opts, :recovery_revision) do
        nil -> {:ok, nil}
        revision when is_integer(revision) and revision > 0 -> {:ok, revision}
        other -> {:error, {:invalid_recovery_revision, other}}
      end
    else
      {:error, {:invalid_recovery_revision, opts}}
    end
  end

  defp put_record(state, %Record{} = record) do
    fifo =
      if Map.has_key?(state.records, record.id) do
        state.fifo
      else
        state.fifo ++ [record.id]
      end

    %{state | records: Map.put(state.records, record.id, record), fifo: fifo}
  end

  defp drop_record(state, id) do
    case Map.fetch(state.records, id) do
      {:ok, _record} ->
        %{state | records: Map.delete(state.records, id), fifo: List.delete(state.fifo, id)}

      :error ->
        state
    end
  end

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
    retained = Enum.flat_map(state.fifo, &retained_record(state, &1))
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
         live_records: map_size(state.records),
         completed_keys: length(state.completed)
       }}
    else
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, {:queue_compaction_failed, Exception.message(error)}}
  end

  defp retained_record(state, id) do
    record = Map.fetch!(state.records, id)

    if record.status == :claimed,
      do: [put_log(record), claim_log(record)],
      else: [put_log(record)]
  end

  defp claim_log(%Record{} = record) do
    %{
      "v" => @version,
      "type" => "claim",
      "id" => record.id,
      "claim_id" => record.claim_id,
      "by" => SessionStore.encode_term(record.claimed_by),
      "until_ms" => record.lease_until_ms
    }
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
