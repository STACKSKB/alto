defmodule Alto.Queue do
  @moduledoc """
  A durable, bounded claim/ack queue. Each queue id owns a GenServer and a
  JSONL log at `queues/<id>.jsonl`. Portable term payloads survive restarts;
  acknowledgements and cancellations append tombstones.

  `put/4` uses business keys: a pending key updates its payload and revision,
  a claimed key rejects, and a blanked key may be queued again. `admit/4`
  uses delivery keys: the first pending value wins, claimed keys reject, and
  completed keys remain duplicates until they leave the bounded window.
  Webhook admission namespaces keys by endpoint and delivery id.

  `claim/3` leases the oldest pending records. Leases survive restart and
  expire lazily back to pending. `claim_bounded/4` also limits encoded wire
  bytes; an oversized head leases nothing. `ack/2` completes and tombstones
  a claim, `release/2` returns it to pending, and `cancel/2` completes a key.

  Record count, completed keys, payloads, keys, and log bytes are bounded.
  Mutations are appended and file-synced before acknowledgement; creation
  and repair sync the directory. A failed append leaves memory unchanged.
  Optional compaction replaces historical entries with retained state.
  Replay discards only a torn trailing write; other corruption fails start.
  """

  use GenServer

  alias Alto.Persistence.Codec
  alias Alto.DurableLog

  @version 7
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
      admission: :business,
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

    * `:id` — required, validated storage-file id;
    * `:dir` — storage directory (default `<state home>/alto/queues`);
    * `:name` — registered process name (default `Alto.Queue`);
    * `:max_records` — pending plus claimed records (default 10,000);
    * `:max_completed` — remembered delivery keys (default 10,000); eviction permits readmission;
    * `:max_payload_bytes` — exact-term payload bound (default 64,000);
    * `:max_key_bytes` — key length bound (default 256);
    * `:max_log_bytes` — replay file bound (default 64 MiB);
    * `:auto_compact` — replace history with retained state when full (default false);
    * `:lease_ms` — claim lease (default 300,000);
    * `:clock` — zero-arity millisecond clock (default system time).

  A torn append tail is discarded and the acknowledged prefix atomically
  restored; complete corruption prevents startup.
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
          {:ok, %{id: pos_integer(), revision: pos_integer(), status: :pending}}
          | {:error, term()}
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
          {:ok, %{id: pos_integer(), revision: pos_integer(), status: :pending}}
          | {:error, term()}
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
  @spec restore(GenServer.server(), binary(), binary(), map(), keyword()) ::
          {:ok, %{id: pos_integer(), revision: pos_integer(), status: :pending}}
          | {:error, term()}
  def restore(server \\ __MODULE__, operation_key, generation_id, payload, opts \\ [])
      when is_list(opts) do
    GenServer.call(server, {:restore, operation_key, generation_id, payload, opts})
  end

  @doc "Claim up to `count` oldest pending records under a fresh lease."
  @spec claim(GenServer.server(), pos_integer(), term()) :: {:ok, [map()]}
  def claim(server \\ __MODULE__, count \\ 1, by \\ nil) when is_integer(count) and count >= 1 do
    GenServer.call(server, {:claim, min(count, @max_claim_count), by, :infinity, %{}})
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
    with :ok <- validate_selector(selector) do
      GenServer.call(
        server,
        {:claim, min(count, @max_claim_count), by, max_bytes, selector}
      )
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
    GenServer.call(server, {:claim, min(count, @max_claim_count), by, max_bytes, %{}})
  end

  @doc "Blank a claimed record (it was handled). The record is removed."
  @spec ack(GenServer.server(), String.t()) :: :ok | {:error, :not_found | :lease_expired}
  def ack(server \\ __MODULE__, claim_id) do
    GenServer.call(server, {:settle, claim_id, :ack, []})
  end

  @doc "Return a claim to pending (the client failed before finishing). Pass `delay_ms:` to delay it."
  @spec release(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def release(server \\ __MODULE__, claim_id, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:settle, claim_id, :release, opts})
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
    with :ok <- Alto.Storage.ensure_private_dir(state.dir, owned: true) do
      if File.exists?(state.path) do
        with :ok <- File.chmod(state.path, 0o600), do: replay(state)
      else
        with {:ok, _} <- compact_log(state, 0), do: {:ok, state}
      end
    end
  end

  defp replay(state) do
    case DurableLog.replay(state.path, state.max_log_bytes, &replay_lines(state, &1)) do
      :missing -> {:ok, state}
      {:read_error, {:too_large, size, max}} -> {:error, {:queue_log_too_large, size, max}}
      {:read_error, reason} -> {:error, {:queue_read_failed, reason}}
      result -> result
    end
  end

  defp replay_lines(state, [snapshot | lines]) do
    with {:ok, state} <- restore_snapshot(state, snapshot) do
      Alto.Result.reduce(Enum.with_index(lines, 2), state, fn {line, number}, state ->
        with {:ok, encoded} <- JSON.decode(line),
             {:ok, command} <- Codec.decode(encoded, max_bytes: state.max_log_bytes) do
          apply_command(command, state)
        else
          _ -> {:error, {:queue_corrupt, state.id, number}}
        end
      end)
    end
  end

  defp replay_lines(_state, []), do: {:error, :invalid_queue_snapshot}

  # The same native commands update live and replayed state. Encoding belongs
  # only at the storage boundary.
  defp apply_command({:put, %Record{} = record}, state) do
    with true <- Enum.sort(Map.keys(record)) == Enum.sort(Map.keys(Record.__struct__())),
         true <- is_binary(record.key) and is_integer(record.revision) and record.revision >= 1,
         true <-
           record.admission in [:business, :delivery, :recovery] and is_integer(record.at_ms),
         true <- valid_lease?(record),
         true <- is_integer(record.id) and record.id >= 1,
         :ok <- validate_generation(record.generation_id),
         :ok <- validate_due(record.not_before_ms) do
      {:ok, %{put_record(state, record) | next_id: max(state.next_id, record.id + 1)}}
    else
      _ -> {:error, :bad_entry}
    end
  end

  defp apply_command({:lease, id, status, claim_id, by, until, due}, state) do
    with {:ok, record} <- fetch_record(state.records, id),
         :ok <- validate_due(due) do
      next = %Record{
        record
        | status: status,
          claim_id: claim_id,
          claimed_by: by,
          lease_until_ms: until,
          not_before_ms: due
      }

      if valid_lease?(next), do: {:ok, put_record(state, next)}, else: {:error, :bad_entry}
    else
      _ -> {:error, :bad_entry}
    end
  end

  defp apply_command({:drop, id}, state) do
    case fetch_record(state.records, id) do
      {:ok, record} -> {:ok, state |> drop_record(id) |> track_completed(record.key)}
      :error -> {:ok, state}
    end
  end

  defp apply_command(_, _), do: {:error, :bad_entry}

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

  def handle_call({:claim, count, by, max_bytes, selector}, _from, state),
    do: do_claim(state, count, by, max_bytes, selector)

  def handle_call({:settle, claim_id, operation, opts}, _from, state) do
    with {:ok, record} <- find_by_claim(state, claim_id),
         true <- record.lease_until_ms > now(state) or {:error, :lease_expired},
         {:ok, due} <- schedule_at(state, opts) do
      log =
        case operation do
          :ack -> {:drop, record.id}
          :release -> lease_command(%Record{unclaim(record) | not_before_ms: due})
        end

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

  def handle_call({:snapshot_page, cursor, limit}, _from, state) do
    records =
      ordered_records(state)
      |> Enum.slice(cursor, limit)
      |> Enum.map(&Map.from_struct/1)

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
        record -> {:ok, Map.from_struct(record)}
      end

    {:reply, reply, state}
  end

  defp cancel_records(state, []) do
    {:reply, {:error, :not_found}, state}
  end

  defp cancel_records(state, victims) do
    commit(state, state, Enum.map(victims, &{:drop, &1.id}), :ok, true)
  end

  # Completed-delivery window: newest-first, unique, bounded. Expiry is
  # honest re-admission — a redelivery past eviction legitimately re-queues.
  defp track_completed(state, key) do
    completed =
      [key | List.delete(state.completed, key)]
      |> Enum.take(max(state.max_completed, 0))

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
        logs = Enum.map(claimed, &lease_command/1)

        commit(state, state, logs, {:ok, Enum.map(claimed, &Map.from_struct/1)}, true)
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
      |> Map.from_struct()
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
          generation = fields[:generation_id] || generate_generation_id()

          operation =
            fields[:operation_key] ||
              if(mode == :delivery, do: key, else: "business-generation:" <> generation)

          {:ok,
           %Record{
             id: state.next_id,
             key: key,
             payload: payload,
             revision: 1,
             at_ms: now(state),
             admission: mode,
             generation_id: generation,
             operation_key: operation,
             not_before_ms: fields[:not_before_ms]
           }}
        end
    end
  end

  defp lease_command(record),
    do:
      {:lease, record.id, record.status, record.claim_id, record.claimed_by,
       record.lease_until_ms, record.not_before_ms}

  defp commit_record(original, current, record) do
    reply = {:ok, Map.take(record, [:id, :revision, :status])}
    commit(original, current, [{:put, record}], reply)
  end

  # Live commands and restart replay apply the same records. Publish state only
  # after the complete mutation has been durably appended.
  defp commit(original, current, records, reply, wrap_error \\ false) do
    with {:ok, next} <-
           Alto.Result.reduce(records, current, &apply_command/2),
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

  defp put_record(state, %Record{} = record),
    do: %{state | records: :gb_trees.enter(record.id, record, state.records)}

  defp ordered_records(state), do: :gb_trees.values(state.records)

  defp drop_record(state, id),
    do: %{state | records: :gb_trees.delete_any(id, state.records)}

  defp fetch_record(records, id) do
    case :gb_trees.lookup(id, records) do
      {:value, record} -> {:ok, record}
      :none -> :error
    end
  end

  # One append per mutation, file-synced before acknowledgement. A failed
  # write leaves state untouched: memory and disk stay in agreement.
  defp append(state, commands) do
    with {:ok, lines} <- Alto.Result.traverse(commands, &encode_command/1),
         :ok <- ensure_log_room(state, IO.iodata_length(lines)),
         do: DurableLog.append(state.path, lines)
  rescue
    error -> {:error, {:queue_unencodable, Exception.message(error)}}
  end

  defp encode_command(command) do
    with {:ok, encoded} <- Codec.encode(command, max_bytes: :erlang.external_size(command)),
         do: {:ok, [JSON.encode!(encoded), "\n"]}
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
    snapshot = {state.next_id, state.completed, ordered_records(state)}

    with {:ok, encoded} <- Codec.encode(snapshot, max_bytes: :erlang.external_size(snapshot)),
         lines <- [
           JSON.encode!(%{"v" => @version, "queue" => state.id, "state" => encoded}),
           "\n"
         ],
         bytes <- IO.iodata_length(lines),
         true <-
           bytes + reserved_bytes <= state.max_log_bytes or
             {:error, {:queue_log_too_large, bytes + reserved_bytes, state.max_log_bytes}},
         {:ok, %{size: before}} <-
           (case File.stat(state.path) do
              {:error, :enoent} -> {:ok, %{size: 0}}
              stat -> stat
            end),
         :ok <- DurableLog.replace(state.path, lines, mode: 0o600) do
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

  # A snapshot is one complete record, so an interrupted snapshot can never be
  # mistaken for a valid prefix followed by a torn append.
  defp restore_snapshot(state, line) do
    with {:ok, %{"v" => @version, "queue" => queue, "state" => encoded}} <- JSON.decode(line),
         true <- queue == state.id,
         {:ok, {next_id, completed, records}} <-
           Codec.decode(encoded, max_bytes: state.max_log_bytes),
         true <- is_integer(next_id) and next_id >= 1 and is_list(completed) and is_list(records),
         true <- Enum.all?(completed, &(validate_key(&1, state) == :ok)),
         true <- length(completed) == MapSet.size(MapSet.new(completed)),
         completed <- Enum.take(completed, state.max_completed),
         {:ok, restored} <-
           Alto.Result.reduce(
             records,
             %{
               state
               | next_id: next_id,
                 completed: completed,
                 completed_set: MapSet.new(completed)
             },
             &apply_command({:put, &1}, &2)
           ),
         true <- :gb_trees.size(restored.records) == length(records) do
      {:ok, restored}
    else
      _ -> {:error, :invalid_queue_snapshot}
    end
  end

  defp log_path(dir, id), do: Path.join(dir, id <> ".jsonl")

  defp validate_id!(id) do
    case validate_id(id) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid queue id: #{inspect(reason)}"
    end
  end
end
