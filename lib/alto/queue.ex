defmodule Alto.Queue do
  @moduledoc """
  A durable, bounded claim/ack record queue (the integration contract, "durable queue").

  One GenServer per queue id, one append-only JSONL log per queue under the
  state home (`queues/<id>.jsonl`). Payloads travel as exact terms (base64
  `term_to_binary`, the `Alto.Session` convention), so a queued record
  survives restarts byte-exact; blanks and cancels persist as tombstones,
  so an audited queue log is append-only like a session log.

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

  @version 1
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
    :legacy_admission
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
    :legacy_admission,
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
      lease_until_ms: nil
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
    * `:lease_ms` — claim lease (default 300,000);
    * `:legacy_admission` — treatment for old log records that do not say
      whether they came from `put/3` or `admit/3`. The safe default is
      `:reject`; pass `:business` or `:delivery` only after classifying that
      queue. New records always persist their admission mode.

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

    legacy_admission = Keyword.get(opts, :legacy_admission, :reject)

    with :ok <- validate_max_completed(max_completed),
         :ok <- validate_legacy_admission(legacy_admission) do
      state = %__MODULE__{
        id: id,
        dir: dir,
        path: log_path(dir, id),
        max_records: Keyword.get(opts, :max_records, @default_max_records),
        max_completed: max_completed,
        max_payload_bytes: Keyword.get(opts, :max_payload_bytes, @default_max_payload_bytes),
        max_key_bytes: Keyword.get(opts, :max_key_bytes, @default_max_key_bytes),
        max_log_bytes: Keyword.get(opts, :max_log_bytes, @default_max_log_bytes),
        lease_ms: Keyword.get(opts, :lease_ms, @default_lease_ms),
        legacy_admission: legacy_admission
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

  defp validate_max_completed(n) when is_integer(n) and n >= 0, do: :ok
  defp validate_max_completed(n), do: {:error, {:invalid_max_completed, n}}

  defp validate_legacy_admission(mode) when mode in [:reject, :business, :delivery], do: :ok

  defp validate_legacy_admission(mode),
    do: {:error, {:invalid_legacy_admission, mode}}

  @doc "Storage directory for queue logs, honouring an explicit override."
  @spec dir(keyword()) :: Path.t()
  def dir(opts \\ []) do
    case Keyword.get(opts, :dir) do
      nil -> Path.join([state_home(), "alto", "queues"])
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
  """
  @spec put(GenServer.server(), binary(), term()) ::
          {:ok, %{id: String.t(), revision: pos_integer(), status: :pending}} | {:error, term()}
  def put(server \\ __MODULE__, key, payload) do
    GenServer.call(server, {:put, key, payload})
  end

  @doc """
  Insert-only source admission keyed by `key` (callers pass a namespaced
  delivery key such as `"endpoint-path:delivery-id"`).

  First wins: a pending key answers `{:error, :duplicate}` without touching
  the stored bytes (even when the redelivered body differs); a claimed key
  answers `{:error, {:key_claimed, key}}`; a key blanked within the
  `max_completed` window answers `{:error, :duplicate}` without creating a
  second work item. Only a fresh key creates a record.
  """
  @spec admit(GenServer.server(), binary(), term()) ::
          {:ok, %{id: String.t(), revision: pos_integer(), status: :pending}} | {:error, term()}
  def admit(server \\ __MODULE__, key, payload) do
    GenServer.call(server, {:admit, key, payload})
  end

  @doc """
  Restore one operator-authorized recovery envelope under its original
  semantic operation identity. The derived recovery delivery key is
  insert-only, so repeating the same restore is harmless.
  """
  @spec restore(GenServer.server(), binary(), binary(), map()) ::
          {:ok, %{id: String.t(), revision: pos_integer(), status: :pending}} | {:error, term()}
  def restore(server \\ __MODULE__, operation_key, generation_id, payload) do
    GenServer.call(server, {:restore, operation_key, generation_id, payload})
  end

  @doc "Claim up to `count` oldest pending records under a fresh lease."
  @spec claim(GenServer.server(), pos_integer(), term()) :: {:ok, [map()]}
  def claim(server \\ __MODULE__, count \\ 1, by \\ nil) when is_integer(count) and count >= 1 do
    GenServer.call(server, {:claim, min(count, @max_claim_count), by})
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

  @doc "Return a claim to pending (the client failed before finishing)."
  @spec release(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def release(server \\ __MODULE__, claim_id) do
    GenServer.call(server, {:release, claim_id})
  end

  @doc "Blank every record for `key` (record cancellation)."
  @spec cancel(GenServer.server(), binary()) :: :ok | {:error, :not_found}
  def cancel(server \\ __MODULE__, key) do
    GenServer.call(server, {:cancel, key})
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

  ## Server implementation

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

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
      {:ok, contents} ->
        replay_contents(state, contents)

      {:error, {:too_large, size, max}} ->
        {:error, {:queue_log_too_large, size, max}}

      {:error, :enoent} ->
        {:ok, state}

      {:error, reason} ->
        {:error, {:queue_read_failed, reason}}
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

  # A crash mid-append leaves a torn final line: bytes with no trailing
  # newline that do not decode. Discard exactly that tail and truncate the
  # file with the last good byte prefix; the committed prefix replays normally.
  # A corrupt line anywhere else still fails the start loudly.
  defp replay_contents(state, "") do
    {:ok, %{state | next_id: 1}}
  end

  defp replay_contents(state, contents) do
    {lines, torn?} = split_log(contents)

    with {:ok, state} <- fold_lines(state, lines) do
      state = trim_completed(state)
      state = %{state | next_id: replay_next_id(state.records)}

      if torn? do
        case DurableLog.replace(state.path, join_lines(lines)) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, {:queue_read_failed, reason}}
        end
      else
        {:ok, state}
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

  # Replayed puts carry their logged ids; new live puts continue past the
  # highest id the log has ever used.
  defp replay_next_id(records) do
    records
    |> Map.keys()
    |> Enum.map(fn "rec-" <> digits -> String.to_integer(digits) end)
    |> case do
      [] -> 1
      ids -> Enum.max(ids) + 1
    end
  end

  defp apply_logged(state, line, number) do
    case JSON.decode(line) do
      {:ok, %{"v" => @version, "type" => type} = entry} when is_binary(type) ->
        log_apply(state, type, entry)

      _other ->
        {:error, {:queue_corrupt, state.id, number}}
    end
  end

  # Replay applies logged transitions only; live ops only log transitions
  # they performed, so replaying reproduces the same state.
  defp log_apply(state, "put", entry) do
    with {:ok, key, payload, revision, mode, generation_id, operation_key} <-
           decode_put(entry, state) do
      {:ok,
       upsert(
         state,
         key,
         payload,
         revision,
         entry["id"],
         entry["at_ms"],
         mode,
         generation_id,
         operation_key
       )}
    end
  end

  defp log_apply(state, "claim", entry) do
    case Map.fetch(state.records, entry["id"]) do
      {:ok, record} ->
        record = %Record{
          record
          | status: :claimed,
            claim_id: entry["claim_id"],
            claimed_by: entry["by"],
            lease_until_ms: entry["until_ms"]
        }

        {:ok, put_record(state, record)}

      :error ->
        {:ok, state}
    end
  end

  defp log_apply(state, "release", entry) do
    case Map.fetch(state.records, entry["id"]) do
      {:ok, record} -> {:ok, put_record(state, unclaim(record))}
      :error -> {:ok, state}
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

  defp decode_put(
         %{"id" => id, "key" => key, "payload" => encoded, "revision" => revision} = entry,
         state
       )
       when is_binary(id) and is_binary(key) and is_integer(revision) and revision >= 1 do
    with {:ok, payload} <- SessionStore.decode_term(encoded),
         {:ok, mode} <- logged_mode(entry, state) do
      generation_id =
        Map.get_lazy(entry, "generation_id", fn -> legacy_generation_id(state.id, id) end)

      if is_binary(generation_id) and generation_id != "" do
        {:ok, key, payload, revision, mode, generation_id, entry["operation_key"]}
      else
        {:error, :bad_entry}
      end
    end
  end

  defp decode_put(_entry, _state), do: {:error, :bad_entry}

  defp upsert(
         state,
         key,
         payload,
         revision,
         id,
         at_ms,
         mode,
         generation_id,
         operation_key
       ) do
    case pending_by_key(state, key) do
      {:ok, record} ->
        put_record(state, %Record{record | payload: payload, revision: revision})

      :error ->
        record = %Record{
          id: id,
          key: key,
          payload: payload,
          revision: revision,
          at_ms: at_ms,
          generation_id: generation_id,
          operation_key: operation_key,
          mode: mode_from_log(mode)
        }

        put_record(state, record)
    end
  end

  @impl true
  def handle_call({:put, key, payload}, _from, state) do
    # Expiry is lazy, but a put on the claimed key is itself a lookup. Keep
    # the original state as the failure rollback point: reclaiming in memory
    # must not make a failed append look durable.
    reclaimed_state = reclaim_expired(state)

    with :ok <- validate_key(key, reclaimed_state),
         :ok <- validate_payload(payload, reclaimed_state),
         {:ok, record, log, next_id} <- build_put(reclaimed_state, key, payload),
         :ok <- append(reclaimed_state, log) do
      {:reply, {:ok, %{id: record.id, revision: record.revision, status: record.status}},
       %{put_record(reclaimed_state, record) | next_id: next_id}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:admit, key, payload}, _from, state) do
    reclaimed_state = reclaim_expired(state)

    with :ok <- validate_key(key, reclaimed_state),
         :ok <- validate_payload(payload, reclaimed_state),
         :ok <- check_not_completed(reclaimed_state, key),
         {:ok, record, log, next_id} <- build_admit(reclaimed_state, key, payload),
         :ok <- append(reclaimed_state, log) do
      {:reply, {:ok, %{id: record.id, revision: record.revision, status: record.status}},
       %{put_record(reclaimed_state, record) | next_id: next_id}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:restore, operation_key, generation_id, payload}, _from, state) do
    reclaimed_state = reclaim_expired(state)
    key = recovery_key(operation_key)

    with :ok <- validate_key(operation_key, reclaimed_state),
         :ok <- validate_generation(generation_id),
         :ok <- validate_payload(payload, reclaimed_state),
         :ok <- check_not_completed(reclaimed_state, key),
         {:ok, record, log, next_id} <-
           build_restore(reclaimed_state, key, operation_key, generation_id, payload),
         :ok <- append(reclaimed_state, log) do
      {:reply, {:ok, %{id: record.id, revision: record.revision, status: record.status}},
       %{put_record(reclaimed_state, record) | next_id: next_id}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:claim, count, by}, _from, state) do
    do_claim(state, count, by, :infinity)
  end

  @impl true
  def handle_call({:claim_bounded, count, by, max_bytes}, _from, state) do
    do_claim(state, count, by, max_bytes)
  end

  @impl true
  def handle_call({:ack, claim_id}, _from, state) do
    case find_by_claim(state, claim_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, record} ->
        now = System.system_time(:millisecond)

        if is_integer(record.lease_until_ms) and record.lease_until_ms <= now do
          {:reply, {:error, :lease_expired}, reclaim_expired(state)}
        else
          log = %{"v" => @version, "type" => "blank", "id" => record.id, "reason" => "acked"}

          case append(state, log) do
            :ok ->
              state =
                state
                |> drop_record(record.id)
                |> track_completed(record.key)

              {:reply, :ok, state}

            {:error, reason} ->
              {:reply, {:error, {:queue_write_failed, reason}}, state}
          end
        end
    end
  end

  def handle_call({:release, claim_id}, _from, state) do
    case find_by_claim(state, claim_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, record} ->
        log = %{"v" => @version, "type" => "release", "id" => record.id}

        case append(state, log) do
          :ok -> {:reply, :ok, put_record(state, unclaim(record))}
          {:error, reason} -> {:reply, {:error, {:queue_write_failed, reason}}, state}
        end
    end
  end

  def handle_call({:cancel, key}, _from, state) do
    victims =
      state.records
      |> Map.values()
      |> Enum.filter(&(&1.key == key))

    case victims do
      [] ->
        {:reply, {:error, :not_found}, state}

      victims ->
        logs =
          Enum.map(victims, fn record ->
            %{"v" => @version, "type" => "blank", "id" => record.id, "reason" => "cancelled"}
          end)

        case append(state, logs) do
          :ok ->
            state = Enum.reduce(victims, state, &drop_record(&2, &1.id))
            {:reply, :ok, track_completed(state, key)}

          {:error, reason} ->
            {:reply, {:error, {:queue_write_failed, reason}}, state}
        end
    end
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

  defp do_claim(state, count, by, budget) do
    state = reclaim_expired(state)

    pending =
      state.fifo
      |> Enum.map(&Map.fetch!(state.records, &1))
      |> Enum.filter(&(&1.status == :pending))
      |> Enum.take(count)

    case select_fitting(pending, budget) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, []} ->
        {:reply, {:ok, []}, state}

      {:ok, fitting} ->
        now = System.system_time(:millisecond)

        {claimed, logs} =
          Enum.map_reduce(fitting, [], fn record, logs ->
            claim_id = fresh_claim_id()
            until = now + state.lease_ms

            record = %Record{
              record
              | status: :claimed,
                claim_id: claim_id,
                claimed_by: by,
                lease_until_ms: until
            }

            log = %{
              "v" => @version,
              "type" => "claim",
              "id" => record.id,
              "claim_id" => claim_id,
              "by" => by,
              "until_ms" => until,
              "at_ms" => now
            }

            {record, [log | logs]}
          end)

        logs = Enum.reverse(logs)

        # One append for the whole batch: either every claim is durable or
        # none is. The previous per-record loop could persist the first
        # claims and then report failure, leaving the caller with no
        # knowledge of the claims it already owned.
        case append(state, logs) do
          :ok ->
            state = Enum.reduce(claimed, state, &put_record(&2, &1))
            {:reply, {:ok, Enum.map(claimed, &view/1)}, state}

          {:error, reason} ->
            {:reply, {:error, {:queue_write_failed, reason}}, state}
        end
    end
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
    now = System.system_time(:millisecond)

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

  defp build_put(state, key, payload) do
    cond do
      # Someone is actively handling this key; the flow retries or the
      # caller treats it as a conflict. Never shadow a claimed record.
      claimed_by_key?(state, key) ->
        {:error, {:key_claimed, key}}

      true ->
        case pending_by_key(state, key) do
          {:ok, record} ->
            # An in-place update consumes no new capacity: the room check
            # applies to fresh records only, so a full queue still accepts
            # order modifications.
            revision = record.revision + 1

            log =
              put_log(
                state.id,
                record.id,
                key,
                payload,
                revision,
                "business",
                record.generation_id
              )

            {:ok, %Record{record | payload: payload, revision: revision}, log, state.next_id}

          :error ->
            with :ok <- validate_room(state) do
              record = new_record(state, key, payload, :business)

              log =
                put_log(
                  state.id,
                  record.id,
                  key,
                  payload,
                  record.revision,
                  "business",
                  record.generation_id
                )

              {:ok, record, log, state.next_id + 1}
            end
        end
    end
  end

  defp claimed_by_key?(state, key) do
    Enum.any?(state.records, fn {_id, %Record{} = record} ->
      record.key == key and record.status == :claimed
    end)
  end

  defp check_not_completed(state, key) do
    if MapSet.member?(state.completed_set, key) do
      {:error, :duplicate}
    else
      :ok
    end
  end

  # Insert-only: a pending delivery key is a redelivery of bytes already
  # accepted — first wins, no update, no revision bump.
  defp build_admit(state, key, payload) do
    cond do
      claimed_by_key?(state, key) ->
        {:error, {:key_claimed, key}}

      pending_by_key(state, key) != :error ->
        {:error, :duplicate}

      true ->
        with :ok <- validate_room(state) do
          record = new_record(state, key, payload, :delivery)

          log =
            put_log(
              state.id,
              record.id,
              key,
              payload,
              record.revision,
              "delivery",
              record.generation_id
            )

          {:ok, record, log, state.next_id + 1}
        end
    end
  end

  defp build_restore(state, key, operation_key, generation_id, payload) do
    cond do
      claimed_by_key?(state, key) ->
        {:error, {:key_claimed, key}}

      pending_by_key(state, key) != :error ->
        {:error, :duplicate}

      true ->
        with :ok <- validate_room(state) do
          record =
            new_record(state, key, payload, :recovery, generation_id, operation_key)

          log =
            put_log(
              state.id,
              record.id,
              key,
              payload,
              record.revision,
              "recovery",
              generation_id,
              operation_key
            )

          {:ok, record, log, state.next_id + 1}
        end
    end
  end

  defp new_record(state, key, payload, mode) do
    new_record(state, key, payload, mode, generate_generation_id(), nil)
  end

  defp new_record(state, key, payload, mode, generation_id, operation_key) do
    %Record{
      id: "rec-" <> Integer.to_string(state.next_id),
      key: key,
      payload: payload,
      revision: 1,
      at_ms: System.system_time(:millisecond),
      generation_id: generation_id,
      operation_key: operation_key,
      mode: mode
    }
  end

  defp put_log(
         id,
         record_id,
         key,
         payload,
         revision,
         mode,
         generation_id,
         operation_key \\ nil
       ) do
    %{
      "v" => @version,
      "type" => "put",
      "id" => record_id,
      "key" => key,
      "payload" => SessionStore.encode_term(payload),
      "revision" => revision,
      "mode" => mode,
      "generation_id" => generation_id,
      "operation_key" => operation_key,
      "at_ms" => System.system_time(:millisecond),
      "queue" => id
    }
  end

  defp pending_by_key(state, key) do
    Enum.find_value(state.fifo, fn id ->
      case Map.fetch!(state.records, id) do
        %Record{key: ^key, status: :pending} = record -> {:ok, record}
        _other -> nil
      end
    end)
    |> case do
      nil -> :error
      found -> found
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
      generation_id: record.generation_id,
      operation_key: record.operation_key,
      admission: record.mode
    }
  end

  defp mode_from_log("delivery"), do: :delivery
  defp mode_from_log("recovery"), do: :recovery
  defp mode_from_log(_other), do: :business

  defp logged_mode(%{"mode" => mode}, _state)
       when mode in ["business", "delivery", "recovery"],
       do: {:ok, mode}

  defp logged_mode(%{"mode" => _mode}, _state), do: {:error, :bad_entry}

  defp logged_mode(_entry, %{legacy_admission: :business}), do: {:ok, "business"}
  defp logged_mode(_entry, %{legacy_admission: :delivery}), do: {:ok, "delivery"}

  defp logged_mode(_entry, state),
    do: {:error, {:queue_migration_required, state.id, :legacy_admission}}

  defp legacy_generation_id(queue_id, record_id), do: "legacy-#{queue_id}-#{record_id}"

  defp generate_generation_id do
    "gen-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp validate_generation(id) when is_binary(id) and byte_size(id) in 1..256, do: :ok
  defp validate_generation(id), do: {:error, {:invalid_generation_id, id}}

  defp recovery_key(operation_key) do
    digest = :crypto.hash(:sha256, operation_key) |> Base.url_encode64(padding: false)
    "recovery-" <> digest
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
        {:error, {:queue_log_too_large, current + append_bytes, state.max_log_bytes}}

      {:error, reason} ->
        {:error, {:queue_write_failed, reason}}
    end
  end

  defp log_path(dir, id), do: Path.join(dir, id <> ".jsonl")

  defp validate_id!(id) do
    case validate_id(id) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid queue id: #{inspect(reason)}"
    end
  end

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
