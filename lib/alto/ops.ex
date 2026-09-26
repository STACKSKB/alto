defmodule Alto.Ops do
  @moduledoc """
  Bounded read-only inspection joining native queue and ledger records.

  Ledger recovery overrides live work: dispatched or uncertain operations are
  never safely retryable. Items retain queue order, followed by ledger-only work
  ranked parked, open, then completed. Inspection never reclaims leases or writes.

  `live` contains identity and lease fields; `ledger` contains identity, revision,
  attempts and bounded scrubbed evidence. Payloads and checkpoint contents are
  excluded. Recovery envelopes expose only their key and generation identity.
  """

  @default_limit 20
  @max_limit 100
  @max_reason_bytes 500

  @type status :: :accepted | :claimed | :parked | :unknown | :completed
  @type filter :: :all | status()

  @type item :: %{
          key: String.t(),
          status: status(),
          live: map() | nil,
          ledger: map() | nil,
          stale: boolean() | nil,
          safe_to_retry: false,
          recovery: String.t()
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
         {:ok, filter} <- validate_filter(Keyword.get(opts, :filter, :all)),
         {:ok, items} <- collect(queue, ledger) do
      items = filter_items(items, filter)
      page = Enum.slice(items, cursor, limit)
      next_cursor = if cursor + limit < length(items), do: cursor + limit, else: nil
      {:ok, %{items: page, next_cursor: next_cursor}}
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
    with {:ok, live} <- snapshot_pages(queue, 0, []),
         live_by_operation = Map.new(live, &{&1.operation_key, &1}),
         {:ok, entries} <-
           ledger_call(fn -> Alto.OperationLog.request(ledger, {:entries, :all}) end) do
      ledger_items =
        entries
        |> Enum.reject(&(&1.status == {:intended} and &1.attempts > 0))
        |> Enum.sort_by(&inspection_rank/1)
        |> Enum.flat_map(fn entry ->
          record = Map.get(live_by_operation, entry.operation_key)

          case disposition(entry, record) do
            nil -> []
            guidance -> [{entry.operation_key, item(record, entry, guidance)}]
          end
        end)

      ledger_by_operation = Map.new(ledger_items)

      merged_live =
        Enum.map(live, fn record ->
          Map.get_lazy(ledger_by_operation, record.operation_key, fn ->
            item(record, nil, live_disposition(record.status))
          end)
        end)

      remaining =
        for {key, item} <- ledger_items, not Map.has_key?(live_by_operation, key), do: item

      {:ok, merged_live ++ remaining}
    end
  end

  defp snapshot_pages(queue, cursor, acc) do
    try do
      case Alto.Queue.request(queue, {:snapshot_page, cursor, 100}) do
        {:ok, %{records: records, next_cursor: next_cursor}} ->
          acc = Enum.reverse(records, acc)

          if is_nil(next_cursor),
            do: {:ok, Enum.reverse(acc)},
            else: snapshot_pages(queue, next_cursor, acc)

        {:error, reason} ->
          {:error, {:queue_unavailable, reason}}
      end
    catch
      :exit, reason -> {:error, {:queue_unavailable, reason}}
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

  defp disposition(%{status: {:intended}}, live) when not is_nil(live), do: nil

  defp disposition(
         %{tool: "workspace", status: {:checkpointed, %{version: 2, status: phase}, _}},
         _live
       )
       when phase in ["intended", "in_progress"],
       do:
         {:unknown,
          "review the retained workspace; discard at its current revision, never blind retry"}

  defp disposition(%{status: {:decided, :requires_operator, _}}, _live),
    do:
      {:parked,
       "operator reviews evidence, then record an outcome and admit a new delivery to re-run"}

  defp disposition(%{status: {:decided, class, _}}, _live)
       when class in [:completed, :failed_known, :rejected_before_dispatch],
       do:
         {:completed,
          "terminal; no action (re-run by admitting a new delivery if business needs it)"}

  defp disposition(%{status: {:decided, :unknown, _}}, _live),
    do: {:unknown, "reconcile the participant or park; never treat unknown as success"}

  defp disposition(%{status: {:dispatched, _}}, _live),
    do:
      {:unknown,
       "reconcile with the authoritative participant, then record an outcome (never blind retry)"}

  defp disposition(%{status: {:intended}}, _live),
    do:
      {:unknown,
       "review inbox/audit; record an outcome under the operation identity if warranted"}

  defp disposition(_entry, _live), do: nil

  defp live_disposition(:pending),
    do: {:accepted, "claim via queue_claim, then handle under the ledger recovery table"}

  defp live_disposition(:claimed),
    do: {:claimed, "await outcome; on expiry the next claim reconciles via the ledger"}

  defp item(live, ledger, {status, guidance}) do
    envelope = ledger && ledger.recovery

    %{
      key: (live && live.key) || (is_map(envelope) && envelope[:key]) || ledger.operation_key,
      status: status,
      live:
        live &&
          Map.take(
            live,
            ~w(id key operation_key generation_id status claim_id claimed_by lease_until_ms)a
          ),
      ledger: ledger && ledger_projection(ledger),
      stale:
        if(live && live.status == :claimed,
          do: live.lease_until_ms <= System.system_time(:millisecond)
        ),
      safe_to_retry: false,
      recovery: guidance
    }
  end

  defp ledger_projection(entry) do
    status =
      case entry.status do
        {:decided, class, evidence} ->
          {:decided, class,
           Alto.Text.truncate(
             inspect(Map.delete(evidence, :__struct__), limit: 10),
             @max_reason_bytes,
             "..."
           )}

        {:checkpointed, checkpoint, attempt} ->
          {:checkpointed, Map.take(checkpoint, [:version, :status, :action]), attempt}

        other ->
          other
      end

    entry
    |> Map.take(~w(operation_key revision tool inbox_key current_attempt attempts)a)
    |> Map.put(:status, status)
    |> Map.put(:recovery, entry.recovery && Map.take(entry.recovery, [:key, :generation_id]))
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
