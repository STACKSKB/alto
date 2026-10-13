defmodule Alto.Contrib.Resident.ChildRuns do
  @moduledoc "Resident aggregate child continuations and read-only operator recovery, backed by Alto."

  alias Alto.OperationLog
  alias Alto.Subagents.Continuation
  alias Alto.Persistence.Codec
  alias Alto.Contrib.Resident.Service

  def child(config, name), do: hd(Alto.Contrib.Resident.ParentRuns.children(config, name))

  @doc "Stable resident aggregate store name for the run's :continuation_store option."
  def ledger(name \\ Service), do: Alto.Contrib.Resident.ParentRuns.ledger(name)

  def commands(name) do
    Map.new(~w(list get result approval), fn action ->
      {"children." <> action, fn args -> execute(ledger(name), action, args) end}
    end)
  end

  defp execute(ledger, "list", args) when is_map(args) do
    cursor = Map.get(args, "cursor", 0)

    if is_integer(cursor) and cursor >= 0 do
      keys =
        ledger
        |> OperationLog.request({:entries, :all})
        |> Enum.map(& &1.operation_key)
        |> Enum.sort()

      page = Enum.slice(keys, cursor, 10)

      batches =
        Enum.map(page, fn key ->
          case read(ledger, key) do
            {:ok, snapshot} -> summary(key, snapshot)
            {:error, reason} -> %{key: key, state: "unavailable", reason: reason}
          end
        end)

      next = cursor + length(page)
      {:ok, %{batches: batches, next_cursor: if(next < length(keys), do: next)}}
    else
      {:error, :invalid_child_cursor}
    end
  end

  defp execute(ledger, "get", %{"key" => key}) when is_binary(key) do
    with {:ok, snapshot} <- read(ledger, key) do
      children =
        Enum.map(snapshot.ids, fn id ->
          child_view(id, snapshot.packet["children"][id])
        end)

      {:ok,
       summary(key, snapshot)
       |> Map.put(:metadata, snapshot.metadata)
       |> Map.put(:children, children)}
    end
  end

  defp execute(ledger, "approval", %{
         "key" => key,
         "child" => id,
         "generation" => generation,
         "revision" => revision
       })
       when is_binary(key) and is_binary(id) and is_binary(generation) and
              byte_size(generation) > 0 and is_integer(revision) and revision > 0 do
    with {:ok, batch} <-
           Continuation.restore(ledger, %{"key" => key, "generation" => generation}),
         {:ok, child} <- Continuation.inspect_approval(batch, revision, id) do
      {:ok,
       %{
         identity: child.identity,
         revision: child.revision,
         state: child.state,
         decision: child.decision,
         request: child.checkpoint["request"]
       }}
    end
  end

  defp execute(
         ledger,
         "result",
         %{"key" => key, "child" => id, "generation" => generation, "revision" => revision} = args
       )
       when is_binary(key) and is_binary(id) and is_binary(generation) and
              is_integer(revision) and revision > 0 do
    with {:ok, snapshot} <- read(ledger, key),
         :ok <- viewed(snapshot, generation, revision),
         {:ok, encoded} <- retained_result(snapshot.packet["children"], id),
         {:ok, chunk} <- chunk(encoded, Map.get(args, "cursor", 0)) do
      {:ok,
       Map.merge(chunk, %{
         key: key,
         child: id,
         generation: generation,
         revision: revision,
         encoding: "alto_portable_term_base64",
         bytes: byte_size(encoded),
         sha256: :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
       })}
    end
  end

  defp execute(_, _, _), do: {:error, :invalid_child_command}

  defp read(ledger, key) do
    with {:ok, batch, snapshot} <- Continuation.lookup(ledger, key),
         do: {:ok, Map.put(snapshot, :identity, Continuation.identity(batch))}
  end

  defp summary(key, snapshot) do
    packet = snapshot.packet

    # List pages need only bounded parent identifiers; detail inspection retains
    # full metadata. Never place every child's result in one transport response.
    metadata =
      snapshot.metadata
      |> Map.take(["parent_run_id", "parent_session_id"])
      |> Map.filter(fn {_key, value} -> is_binary(value) and byte_size(value) <= 256 end)

    %{
      key: key,
      generation: snapshot.identity["generation"],
      revision: snapshot.revision,
      state: to_string(snapshot.state),
      metadata: metadata,
      counts: Enum.frequencies_by(Map.values(packet["children"]), &to_string(elem(&1, 0))),
      joined: snapshot.phase in [:ready, :claimed] or is_map(packet["join"])
    }
  end

  defp viewed(
         %{revision: revision, identity: %{"generation" => generation}},
         generation,
         revision
       ),
       do: :ok

  defp viewed(_, _, _), do: {:error, :stale_child_batch}

  defp retained_result(children, id) do
    case children[id] do
      {:completed, _, result} -> Codec.encode(result)
      child when is_tuple(child) -> {:error, {:child_result_pending, to_string(elem(child, 0))}}
      nil -> {:error, :unknown_child}
    end
  end

  defp child_view(id, child) do
    base = %{"id" => id, "state" => to_string(elem(child, 0)), "suspension" => nil}

    case Tuple.to_list(child) do
      [:planned] ->
        base

      [state, attempt | _] when state in [:dispatched, :completed] ->
        Map.put(base, "attempt", attempt)

      [:suspended, attempt, token, _] ->
        Map.merge(base, %{"attempt" => attempt, "suspension" => token})

      [state, attempt, token, _, decision | _] when state in [:decided, :resuming] ->
        Map.merge(base, %{
          "attempt" => attempt,
          "suspension" => token,
          "decision" => to_string(decision)
        })
    end
  end

  # Export the portable encoding of the validated retained term. Export never
  # acknowledges consumption.
  defp chunk(encoded, cursor)
       when is_integer(cursor) and cursor >= 0 and cursor <= byte_size(encoded) do
    count = min(24_000, byte_size(encoded) - cursor)
    next = cursor + count

    {:ok,
     %{
       chunk: binary_part(encoded, cursor, count),
       next_cursor: if(next < byte_size(encoded), do: next)
     }}
  end

  defp chunk(_, _), do: {:error, :invalid_child_cursor}
end
