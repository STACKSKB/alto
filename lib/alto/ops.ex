defmodule Alto.Ops do
  @moduledoc """
  Bounded read-only operator inspection over the decided contracts.

  Unifies the live inbox (`Alto.Queue`) with the operation ledger
  (`Alto.OperationLog`) into five work states, exactly as the contracts
  define them:

    * `:accepted` — live pending records (queued, unclaimed);
    * `:claimed` — live claimed records under lease, with `stale?` computed
      from `lease_until_ms` against now (a stale claim is an expired lease
      awaiting lazy reclaim — still owned on paper, re-claimable in fact);
    * `:parked` — ledger `:requires_operator` outcomes (left the live queue;
      re-run by admitting a new delivery, never automatically);
    * `:unknown` — ledger dispatched-without-outcome (an attempt exists, no
      outcome): recovery must reconcile with the participant or park —
      **never shown as safely retryable** (`safe_to_retry: false`);
    * `:completed` — ledger decided terminal outcomes other than parked or
      unknown (`:completed`, `:failed_known`, `:rejected_before_dispatch`).

  Correlation per item: `source` (delivery namespace before `":"`, else
  `"business"`), `operation` (the delivery/inbox key), and
  `operation_key` (the semantic operation key when the queue record carries
  one). Live items include `record_id` / `claim_id` / `claimed_by` /
  `lease_until_ms`; ledger items include `attempts`, bounded `reason`
  (scrubbed evidence, truncated), `generation_id`, `operation_revision`, and
  `attempt_id`. Short flows correlate by external id (the integration contract run-shape
  decision), not by a resident run id — there is no run to join.

  Bounds: pages hold at most `limit` items
  (default 20, max 100); reasons truncate to 500 bytes; queue inspection
  reads bounded pages until the queue's configured live-record bound is
  exhausted; ledger enumeration is bounded by `max_ops`. Recovery actions
  are described as explicit requests (`recovery:` hint naming the existing
  queue/ledger call with its required identity) — this module exposes no
  mutating function and grants no new authority. Unknown work never
  carries a retry action.
  """

  @default_limit 20
  @max_limit 100
  @max_reason_bytes 500

  @type status :: :accepted | :claimed | :parked | :unknown | :completed
  @type filter :: :all | status()

  @type item :: %{
          key: String.t(),
          status: status(),
          source: String.t(),
          operation: String.t(),
          operation_key: String.t(),
          record_id: String.t() | nil,
          claim_id: String.t() | nil,
          claimed_by: term(),
          lease_until_ms: integer() | nil,
          stale: boolean() | nil,
          attempts: non_neg_integer(),
          reason: String.t(),
          safe_to_retry: boolean(),
          recovery: String.t(),
          generation_id: String.t() | nil,
          operation_revision: pos_integer() | nil,
          attempt_id: String.t() | nil,
          recovery_available: boolean()
        }

  @doc """
  List work items with pagination. Options:

    * `:limit` — page size, 1..100 (default 20);
    * `:cursor` — zero-based offset into the filtered list (default 0);
    * `:filter` — `:all` or one status (default `:all`).

  Returns `{:ok, %{items: [item()], next_cursor: integer() | nil}}`;
  `next_cursor` is nil at the end. Invalid options fail closed.
  """
  @spec list(GenServer.server(), GenServer.server(), keyword()) ::
          {:ok, %{items: [item()], next_cursor: integer() | nil}} | {:error, term()}
  def list(queue, ledger, opts \\ []) do
    with {:ok, limit} <- validate_limit(Keyword.get(opts, :limit, @default_limit)),
         {:ok, cursor} <- validate_cursor(Keyword.get(opts, :cursor, 0)),
         {:ok, filter} <- validate_filter(Keyword.get(opts, :filter, :all)) do
      with {:ok, items} <- collect(queue, ledger) do
        items = filter_items(items, filter)
        page = Enum.slice(items, cursor, limit)
        next_cursor = if cursor + limit < length(items), do: cursor + limit, else: nil
        {:ok, %{items: page, next_cursor: next_cursor}}
      end
    end
  catch
    :exit, reason -> {:error, {:ops_unavailable, reason}}
  end

  @doc "Single-operation detail (same bounds as `list/3`)."
  @spec get(GenServer.server(), GenServer.server(), String.t()) ::
          {:ok, item()} | {:error, :not_found | term()}
  def get(queue, ledger, key) when is_binary(key) do
    with {:ok, items} <- collect(queue, ledger) do
      case Enum.find(items, &(&1.key == key)) do
        nil -> {:error, :not_found}
        item -> {:ok, item}
      end
    end
  catch
    :exit, reason -> {:error, {:ops_unavailable, reason}}
  end

  ## Collection (read-only; never writes, never reclaims eagerly)

  defp collect(queue, ledger) do
    with {:ok, live} <- live_items(queue),
         live_by_key =
           Enum.reduce(live, %{}, fn item, acc ->
             acc
             |> Map.put(item.key, item)
             |> Map.put(Map.get(item, :operation_key, item.operation), item)
           end),
         {:ok, ledger_only} <- ledger_items_complete(ledger, live_by_key) do
      ledger_by_key =
        Enum.reduce(ledger_only, %{}, fn item, acc ->
          acc
          |> Map.put(item.key, item)
          |> Map.put(Map.get(item, :operation_key, item.key), item)
        end)

      # Ledger recovery state overrides the live view when both exist: a
      # dispatched key that looks pending live must still read as unknown —
      # the recovery table forbids blind re-dispatch of dispatched work.
      merged_live =
        Enum.map(live, fn item ->
          Map.get(
            ledger_by_key,
            Map.get(item, :operation_key, item.operation),
            Map.get(ledger_by_key, item.key, item)
          )
        end)

      {:ok,
       merged_live ++
         Enum.reject(ledger_only, fn item ->
           Map.has_key?(live_by_key, item.key) or
             Map.has_key?(live_by_key, Map.get(item, :operation_key, item.key))
         end)}
    end
  end

  defp live_items(queue) do
    with {:ok, records} <- snapshot_pages(queue, 0, []) do
      {:ok,
       Enum.map(records, fn record ->
         generation_id = Map.get(record, :generation_id)
         now = System.system_time(:millisecond)

         case record.status do
           :pending ->
             %{
               key: record.key,
               status: :accepted,
               source: source_of(record.key),
               operation: record.key,
               operation_key: operation_of(record),
               record_id: record.id,
               claim_id: nil,
               claimed_by: nil,
               lease_until_ms: nil,
               stale: nil,
               attempts: 0,
               reason: "pending; awaiting claim",
               safe_to_retry: false,
               recovery: "claim via queue_claim, then handle under the ledger recovery table",
               generation_id: generation_id,
               operation_revision: nil,
               attempt_id: nil,
               recovery_available: false
             }

           :claimed ->
             stale? =
               is_integer(record.lease_until_ms) and record.lease_until_ms <= now

             %{
               key: record.key,
               status: :claimed,
               source: source_of(record.key),
               operation: record.key,
               operation_key: operation_of(record),
               record_id: record.id,
               claim_id: record.claim_id,
               claimed_by: record.claimed_by,
               lease_until_ms: record.lease_until_ms,
               stale: stale?,
               attempts: 0,
               reason:
                 if(stale?,
                   do: "lease expired; re-claimable, current owner is stale",
                   else: "claimed under lease"
                 ),
               safe_to_retry: false,
               recovery: "await outcome; on expiry the next claim reconciles via the ledger",
               generation_id: generation_id,
               operation_revision: nil,
               attempt_id: record.claim_id,
               recovery_available: false
             }
         end
       end)}
    end
  end

  defp snapshot_pages(queue, cursor, acc) do
    try do
      case Alto.Queue.snapshot_page(queue, cursor, 100) do
        {:ok, %{records: records, next_cursor: nil}} ->
          {:ok, acc ++ records}

        {:ok, %{records: records, next_cursor: next_cursor}} ->
          snapshot_pages(queue, next_cursor, acc ++ records)

        {:error, reason} ->
          {:error, {:queue_unavailable, reason}}
      end
    catch
      :exit, reason -> {:error, {:queue_unavailable, reason}}
    end
  end

  defp ledger_items_complete(ledger, live_by_key) do
    with :ok <- ensure_server(ledger, :ledger) do
      with {:ok, parked} <- ledger_call(fn -> Alto.OperationLog.list_parked(ledger) end),
           {:ok, decided} <- ledger_call(fn -> Alto.OperationLog.list_decided(ledger) end),
           {:ok, open} <- ledger_call(fn -> Alto.OperationLog.list_open(ledger) end) do
        ledger_keys = (parked ++ open ++ Enum.map(decided, &elem(&1, 0))) |> Enum.uniq()

        Enum.reduce_while(ledger_keys, {:ok, []}, fn key, {:ok, items} ->
          with {:ok, status} <- ledger_call(fn -> Alto.OperationLog.status(ledger, key) end),
               {:ok, attempts} <- ledger_call(fn -> Alto.OperationLog.attempts(ledger, key) end),
               {:ok, recovery} <- recovery_call(ledger, key) do
            live = Map.get(live_by_key, key)
            rows = ledger_rows(status, key, attempts, recovery, live)

            {:cont, {:ok, items ++ rows}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    end
  end

  defp ledger_call(fun) do
    try do
      {:ok, fun.()}
    catch
      :exit, reason -> {:error, {:ledger_unavailable, reason}}
    end
  end

  defp recovery_call(ledger, key) do
    case ledger_call(fn -> Alto.OperationLog.recovery(ledger, key) end) do
      {:ok, {:ok, recovery}} -> {:ok, recovery}
      {:ok, {:error, :not_found}} -> {:ok, nil}
      {:ok, {:error, reason}} -> {:error, {:ledger_unavailable, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_identity(item, recovery, live) do
    envelope = if is_map(recovery), do: Map.get(recovery, :recovery), else: nil
    display_key = (live && live.key) || (is_map(envelope) && Map.get(envelope, :key)) || item.key
    display_source = (live && live.source) || source_of(display_key)
    display_operation = (live && live.operation) || display_key
    operation_key = Map.get(item, :operation_key, item.key)

    Map.merge(item, %{
      key: display_key,
      source: display_source,
      operation: display_operation,
      operation_key: operation_key,
      generation_id: recovery_generation(envelope, live),
      operation_revision: recovery && recovery.revision,
      attempt_id: (recovery && recovery.current_attempt) || (live && live.claim_id),
      recovery_available: is_map(envelope)
    })
  end

  defp recovery_generation(envelope, live) when is_map(envelope) do
    Map.get(envelope, :generation_id) || (live && live.generation_id)
  end

  defp recovery_generation(_envelope, live), do: live && live.generation_id

  defp operation_of(record) do
    case Map.get(record, :admission) do
      :business -> "business-generation:" <> record.generation_id
      _other -> record.key
    end
  end

  defp ledger_rows({:decided, :requires_operator, evidence}, key, attempts, recovery, live) do
    item =
      ledger_item(
        key,
        :parked,
        attempts,
        reason_of(evidence, :parked),
        "operator reviews evidence, then record_outcome + admit a new delivery to re-run",
        live
      )

    [add_identity(item, recovery, live)]
  end

  defp ledger_rows({:decided, class, evidence}, key, attempts, recovery, live)
       when class in [:completed, :failed_known, :rejected_before_dispatch] do
    item =
      ledger_item(
        key,
        :completed,
        attempts,
        reason_of(evidence, class),
        "terminal; no action (re-run by admitting a new delivery if business needs it)",
        live
      )

    [add_identity(item, recovery, live)]
  end

  defp ledger_rows({:decided, :unknown, evidence}, key, attempts, recovery, live) do
    item =
      ledger_item(
        key,
        :unknown,
        attempts,
        reason_of(evidence, :unknown),
        "reconcile the participant or park; never treat unknown as success",
        live
      )

    [add_identity(item, recovery, live)]
  end

  defp ledger_rows({:dispatched, _attempt}, key, attempts, recovery, live) do
    item =
      ledger_item(
        key,
        :unknown,
        attempts,
        "dispatched without outcome; reconcile with the participant or park",
        "reconcile with the authoritative participant, then record_outcome (never blind retry)",
        live
      )

    [add_identity(item, recovery, live)]
  end

  defp ledger_rows({:intended}, _key, _attempts, _recovery, live) when not is_nil(live), do: []

  defp ledger_rows({:intended}, key, attempts, recovery, live) do
    item =
      ledger_item(
        key,
        :unknown,
        attempts,
        "live work gone with no recorded outcome; operator review",
        "review inbox/audit; record_outcome under the operation identity if warranted",
        live
      )

    [add_identity(item, recovery, live)]
  end

  defp ledger_rows(_status, _key, _attempts, _recovery, _live), do: []

  defp ledger_item(key, status, attempts, reason, recovery, live) do
    %{
      key: key,
      status: status,
      source: source_of(key),
      operation: key,
      record_id: live && live.record_id,
      claim_id: live && live.claim_id,
      claimed_by: live && live.claimed_by,
      lease_until_ms: live && live.lease_until_ms,
      stale: live && live.stale,
      attempts: attempts,
      reason: reason,
      safe_to_retry: false,
      recovery: recovery
    }
  end

  defp ensure_server(server, kind) do
    pid = if is_pid(server), do: server, else: Process.whereis(server)

    if is_pid(pid) and Process.alive?(pid), do: :ok, else: {:error, {kind, :unavailable}}
  end

  defp source_of(key) do
    case String.split(key, ":", parts: 2) do
      [source, _rest] when source != "" -> source
      _other -> "business"
    end
  end

  defp reason_of(evidence, class) when is_map(evidence) do
    base = "#{class}: #{inspect(Map.delete(evidence, :__struct__), limit: 10)}"
    truncate(base, @max_reason_bytes)
  end

  defp reason_of(_evidence, class), do: "#{class}"

  defp truncate(binary, max) when is_binary(binary) do
    if byte_size(binary) <= max do
      binary
    else
      # Reserve 3 bytes for the ASCII ellipsis so the total stays bounded.
      kept = binary_part(binary, 0, max - 3)
      kept = if String.valid?(kept), do: kept, else: trim_last_byte(kept)
      kept <> "..."
    end
  end

  defp trim_last_byte(<<>>), do: <<>>

  defp trim_last_byte(binary) do
    trimmed = binary_part(binary, 0, byte_size(binary) - 1)
    if String.valid?(trimmed), do: trimmed, else: trim_last_byte(trimmed)
  end

  defp filter_items(items, :all), do: items
  defp filter_items(items, status), do: Enum.filter(items, &(&1.status == status))

  defp validate_limit(n) when is_integer(n) and n >= 1 and n <= @max_limit, do: {:ok, n}
  defp validate_limit(n), do: {:error, {:invalid_limit, n}}

  defp validate_cursor(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp validate_cursor(n), do: {:error, {:invalid_cursor, n}}

  defp validate_filter(f) when f in [:all, :accepted, :claimed, :parked, :unknown, :completed],
    do: {:ok, f}

  defp validate_filter(f), do: {:error, {:invalid_filter, f}}
end
