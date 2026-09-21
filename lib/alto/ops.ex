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
         live_by_operation = Map.new(live, &{&1.operation_key, &1}),
         {:ok, ledger_items} <- ledger_items_complete(ledger, live_by_operation) do
      ledger_by_operation = Map.new(ledger_items, &{&1.operation_key, &1})

      # Ledger recovery state overrides the live view when both exist: a
      # dispatched key that looks pending live must still read as unknown —
      # the recovery table forbids blind re-dispatch of dispatched work.
      merged_live =
        Enum.map(live, fn item ->
          Map.get(ledger_by_operation, item.operation_key, item)
        end)

      {:ok,
       merged_live ++
         Enum.reject(ledger_items, &Map.has_key?(live_by_operation, &1.operation_key))}
    end
  end

  defp live_items(queue) do
    with {:ok, records} <- snapshot_pages(queue, 0, []) do
      {:ok,
       Enum.map(records, fn record ->
         base = %{
           key: record.key,
           source: source_of(record.key),
           operation: record.key,
           operation_key: operation_of(record),
           record_id: record.id,
           attempts: 0,
           safe_to_retry: false,
           generation_id: record.generation_id,
           operation_revision: nil,
           recovery_available: false
         }

         case record.status do
           :pending ->
             Map.merge(base, %{
               status: :accepted,
               claim_id: nil,
               claimed_by: nil,
               lease_until_ms: nil,
               stale: nil,
               reason: "pending; awaiting claim",
               recovery: "claim via queue_claim, then handle under the ledger recovery table",
               attempt_id: nil
             })

           :claimed ->
             stale? =
               is_integer(record.lease_until_ms) and
                 record.lease_until_ms <= System.system_time(:millisecond)

             Map.merge(base, %{
               status: :claimed,
               claim_id: record.claim_id,
               claimed_by: record.claimed_by,
               lease_until_ms: record.lease_until_ms,
               stale: stale?,
               reason:
                 if(stale?,
                   do: "lease expired; re-claimable, current owner is stale",
                   else: "claimed under lease"
                 ),
               recovery: "await outcome; on expiry the next claim reconciles via the ledger",
               attempt_id: record.claim_id
             })
         end
       end)}
    end
  end

  defp snapshot_pages(queue, cursor, acc) do
    try do
      case Alto.Queue.snapshot_page(queue, cursor, 100) do
        {:ok, %{records: records, next_cursor: nil}} ->
          {:ok, Enum.reverse(Enum.reduce(records, acc, &[&1 | &2]))}

        {:ok, %{records: records, next_cursor: next_cursor}} ->
          snapshot_pages(queue, next_cursor, Enum.reduce(records, acc, &[&1 | &2]))

        {:error, reason} ->
          {:error, {:queue_unavailable, reason}}
      end
    catch
      :exit, reason -> {:error, {:queue_unavailable, reason}}
    end
  end

  defp ledger_items_complete(ledger, live_by_operation) do
    with :ok <- ensure_server(ledger, :ledger) do
      with {:ok, entries} <- ledger_call(fn -> Alto.OperationLog.entries(ledger) end) do
        {:ok,
         entries
         |> Enum.reject(&(&1.status == {:intended} and &1.attempts > 0))
         |> Enum.sort_by(&inspection_rank/1)
         |> Enum.flat_map(fn entry ->
           live = Map.get(live_by_operation, entry.operation_key)

           ledger_rows(entry, live)
         end)}
      end
    end
  end

  defp inspection_rank(%{status: {:decided, :requires_operator, _}}), do: 0

  defp inspection_rank(%{status: status})
       when elem(status, 0) in [:intended, :dispatched, :checkpointed],
       do: 1

  defp inspection_rank(_entry), do: 2

  defp ledger_call(fun) do
    try do
      {:ok, fun.()}
    catch
      :exit, reason -> {:error, {:ledger_unavailable, reason}}
    end
  end

  defp operation_of(%{operation_key: key}) when is_binary(key), do: key
  defp operation_of(%{admission: :business, generation_id: id}), do: "business-generation:" <> id
  defp operation_of(record), do: record.key

  defp ledger_rows(%{status: {:intended}}, live) when not is_nil(live), do: []

  defp ledger_rows(entry, live) do
    case ledger_disposition(entry.status) do
      nil -> []
      disposition -> [ledger_item(entry, live, disposition)]
    end
  end

  defp ledger_disposition({:decided, :requires_operator, evidence}),
    do:
      {:parked, reason_of(evidence, :parked),
       "operator reviews evidence, then record_outcome + admit a new delivery to re-run"}

  defp ledger_disposition({:decided, class, evidence})
       when class in [:completed, :failed_known, :rejected_before_dispatch],
       do:
         {:completed, reason_of(evidence, class),
          "terminal; no action (re-run by admitting a new delivery if business needs it)"}

  defp ledger_disposition({:decided, :unknown, evidence}),
    do:
      {:unknown, reason_of(evidence, :unknown),
       "reconcile the participant or park; never treat unknown as success"}

  defp ledger_disposition({:dispatched, _attempt}),
    do:
      {:unknown, "dispatched without outcome; reconcile with the participant or park",
       "reconcile with the authoritative participant, then record_outcome (never blind retry)"}

  defp ledger_disposition({:intended}),
    do:
      {:unknown, "live work gone with no recorded outcome; operator review",
       "review inbox/audit; record_outcome under the operation identity if warranted"}

  defp ledger_disposition(_status), do: nil

  defp ledger_item(entry, live, {status, reason, recovery}) do
    envelope = entry.recovery
    key = (live && live.key) || (is_map(envelope) && envelope[:key]) || entry.operation_key
    generation = (is_map(envelope) && envelope[:generation_id]) || (live && live.generation_id)

    %{
      key: key,
      status: status,
      source: source_of(key),
      operation: key,
      operation_key: entry.operation_key,
      record_id: live && live.record_id,
      claim_id: live && live.claim_id,
      claimed_by: live && live.claimed_by,
      lease_until_ms: live && live.lease_until_ms,
      stale: live && live.stale,
      attempts: entry.attempts,
      reason: reason,
      safe_to_retry: false,
      recovery: recovery,
      generation_id: generation,
      operation_revision: entry.revision,
      attempt_id: entry.current_attempt || (live && live.claim_id),
      recovery_available: is_map(envelope)
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

  defp truncate(binary, max), do: Alto.Text.truncate(binary, max, "...")

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
