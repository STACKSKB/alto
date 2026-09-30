defmodule Alto.Session.Conversation.Store do
  @moduledoc false
  alias Alto.{AtomicFile, BoundedFile, Session, Storage}

  @chunk_messages 64
  @max_bytes 16_000_000

  # Payloads are content-addressed independently of their position. Small,
  # persistent reference chunks share completed prefixes across revisions.
  def plan(id, messages, opts) do
    {refs, objects} =
      Enum.map_reduce(messages, %{}, fn message, objects ->
        encoded = JSON.encode!(message)
        hash = hash(encoded)
        {hash, Map.put(objects, {"message", hash}, encoded)}
      end)

    {root, _, objects} =
      refs
      |> Enum.chunk_every(@chunk_messages)
      |> Enum.reduce({nil, 0, objects}, fn refs, {previous, count, objects} ->
        count = count + length(refs)
        encoded = JSON.encode!(%{"previous" => previous, "messages" => refs, "count" => count})
        root = hash(encoded)
        {root, count, Map.put(objects, {"node", root}, encoded)}
      end)

    with {:ok, missing} <- missing_objects(id, objects, opts) do
      {:ok,
       %{
         root: root,
         count: length(refs),
         objects: objects,
         missing: missing,
         added_bytes: Enum.reduce(missing, 0, fn {_, bytes}, sum -> sum + byte_size(bytes) end)
       }}
    end
  rescue
    error -> {:error, {:session_unencodable, Exception.message(error)}}
  end

  defp missing_objects(id, objects, opts) do
    Alto.Result.reduce(objects, [], fn {key, encoded}, missing ->
      path = object_path(id, key, opts)

      case BoundedFile.read(path, @max_bytes) do
        {:ok, ^encoded} -> {:ok, missing}
        {:error, :enoent} -> {:ok, [{path, encoded} | missing]}
        _ -> {:error, {:conversation_object_corrupt, id, elem(key, 1)}}
      end
    end)
  end

  def write(plan) do
    Alto.Result.reduce(plan.missing, :ok, fn {path, encoded}, :ok ->
      with :ok <- Storage.ensure_private_dir(Path.dirname(path), owned: true),
           :ok <- AtomicFile.write(path, encoded, mode: 0o600),
           do: {:ok, :ok}
    end)
    |> unwrap()
  end

  def read(id, root, count, opts)
      when is_integer(count) and count >= 0 and count <= @max_bytes do
    with {:ok, chunks, _seen} <- nodes(id, root, count, opts, [], MapSet.new()),
         {:ok, {messages, _bytes}} <-
           Alto.Result.reduce(List.flatten(chunks), {[], 0}, fn ref, {messages, bytes} ->
             with {:ok, encoded} <- read_object(id, {"message", ref}, opts),
                  total <- bytes + byte_size(encoded),
                  true <- total <= @max_bytes,
                  {:ok, message} when is_map(message) <- JSON.decode(encoded) do
               {:ok, {[message | messages], total}}
             else
               _ -> {:error, {:conversation_object_corrupt, id, ref}}
             end
           end) do
      {:ok, Enum.reverse(messages)}
    end
  end

  def read(id, _, _, _), do: {:error, {:conversation_object_corrupt, id, :root}}

  defp nodes(_id, nil, 0, _opts, chunks, seen), do: {:ok, chunks, seen}

  defp nodes(id, root, count, opts, chunks, seen) when count > 0 do
    with {:ok, previous, refs} <- node(id, root, count, opts) do
      seen = Enum.reduce(refs, MapSet.put(seen, {"node", root}), &MapSet.put(&2, {"message", &1}))
      nodes(id, previous, count - length(refs), opts, [refs | chunks], seen)
    end
  end

  defp nodes(id, root, _, _, _, _), do: {:error, {:conversation_object_corrupt, id, root}}

  defp node(id, root, count, opts) do
    with {:ok, encoded} <- read_object(id, {"node", root}, opts),
         {:ok, %{"previous" => previous, "messages" => refs, "count" => ^count} = node} <-
           JSON.decode(encoded),
         true <- map_size(node) == 3 and is_list(refs) and length(refs) in 1..@chunk_messages,
         true <- count >= length(refs) and Enum.all?(refs, &valid_hash?/1),
         true <- is_nil(previous) or valid_hash?(previous) do
      {:ok, previous, refs}
    else
      _ -> {:error, {:conversation_object_corrupt, id, root}}
    end
  end

  defp read_object(id, {kind, ref}, opts) do
    if valid_hash?(ref) do
      source =
        case Keyword.get(opts, :conversation_objects, %{})[{kind, ref}] do
          nil -> BoundedFile.read(object_path(id, {kind, ref}, opts), @max_bytes)
          encoded -> {:ok, encoded}
        end

      with {:ok, encoded} <- source, true <- hash(encoded) == ref, do: {:ok, encoded}
    else
      {:error, :invalid_hash}
    end
  end

  def disk_bytes(id, opts) do
    with {:ok, files} <- files(id, opts),
         {:ok, sizes} <- sizes(files),
         do: {:ok, Enum.reduce(sizes, 0, fn {_, size}, n -> n + size end)}
  end

  # Prepared under the session lock, then applied only after the new atomic
  # head commits. The current transcript pins every message it still needs.
  def retention(id, record, limit, opts) do
    with {:ok, revisions} <- revision_files(id, opts),
         {:ok, {drop, keep}} <-
           Alto.Result.reduce(
             revisions,
             {[], [record | Keyword.get(opts, :conversation_pins, [])]},
             fn path, {drop, keep} ->
               with {:ok, encoded} <- BoundedFile.read(path, @max_bytes),
                    {:ok, old} when is_map(old) <- JSON.decode(encoded),
                    true <- old["v"] in [4, 5] and old["session_id"] == id,
                    turn when is_integer(turn) and turn > 0 <-
                      old["turn"] ||
                        max(Enum.count(old["messages"] || [], &(&1["role"] == "user")), 1) do
                 if is_integer(limit) and turn < max(record["turn"] - limit + 1, 1),
                   do: {:ok, {[path | drop], keep}},
                   else: {:ok, {drop, [old | keep]}}
               else
                 _ -> {:error, {:conversation_corrupt, id, :retention}}
               end
             end
           ),
         {:ok, seen} <- reachable(id, keep, opts),
         {:ok, objects} <- object_files(id, opts),
         unused <- Enum.reject(objects, fn path -> MapSet.member?(seen, Path.basename(path)) end),
         {:ok, sizes} <- sizes(drop ++ unused) do
      {:ok, %{files: drop ++ unused, bytes: Enum.reduce(sizes, 0, fn {_, n}, sum -> sum + n end)}}
    end
  end

  defp reachable(id, records, opts) do
    result =
      Alto.Result.reduce(records, %{}, fn
        %{"v" => 5, "message_root" => root, "message_count" => count}, seen ->
          reachable_nodes(id, root, count, opts, seen)

        %{"v" => 4}, seen ->
          {:ok, seen}

        _, _ ->
          {:error, {:conversation_corrupt, id, :retention}}
      end)

    with {:ok, seen} <- result do
      {:ok, MapSet.new(Map.keys(seen), fn {kind, hash} -> "#{kind}-#{hash}.json" end)}
    end
  end

  defp reachable_nodes(_id, nil, 0, _opts, seen), do: {:ok, seen}

  defp reachable_nodes(id, root, count, opts, seen) when is_integer(count) and count > 0 do
    # Visit each shared chunk once during collection, rather than walking every
    # revision's entire prefix again. Counts remain checked on shared edges.
    case Map.fetch(seen, {"node", root}) do
      {:ok, ^count} ->
        {:ok, seen}

      {:ok, _} ->
        {:error, {:conversation_object_corrupt, id, root}}

      :error ->
        with {:ok, previous, refs} <- node(id, root, count, opts) do
          seen =
            Enum.reduce(
              refs,
              Map.put(seen, {"node", root}, count),
              &Map.put(&2, {"message", &1}, true)
            )

          reachable_nodes(id, previous, count - length(refs), opts, seen)
        end
    end
  end

  defp reachable_nodes(id, root, _, _, _), do: {:error, {:conversation_object_corrupt, id, root}}

  def prune(%{files: files}) do
    {revisions, objects} =
      Enum.split_with(files, &String.starts_with?(Path.basename(&1), "revision-"))

    # Persist removal of referencing manifests before reclaiming their objects.
    # A crash must never resurrect an archive whose payload was already deleted.
    with :ok <- prune_files(revisions), do: prune_files(objects)
  end

  defp prune_files(files) do
    dirs = Enum.map(files, &Path.dirname/1) |> Enum.uniq()

    with {:ok, :ok} <-
           Alto.Result.reduce(files, :ok, fn path, :ok ->
             case File.rm(path) do
               :ok -> {:ok, :ok}
               {:error, :enoent} -> {:ok, :ok}
               {:error, reason} -> {:error, {:conversation_prune_failed, reason}}
             end
           end),
         {:ok, :ok} <-
           Alto.Result.reduce(dirs, :ok, fn dir, :ok ->
             with :ok <- AtomicFile.sync_directory(dir), do: {:ok, :ok}
           end),
         do: :ok
  end

  def revision_files(id, opts) do
    case File.ls(dir(id, opts)) do
      {:ok, names} ->
        {:ok,
         names
         |> Enum.filter(&Regex.match?(~r/^revision-\d+\.json$/, &1))
         |> Enum.map(&Path.join(dir(id, opts), &1))}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:conversation_read_failed, reason}}
    end
  end

  defp object_files(id, opts) do
    path = Path.join(dir(id, opts), "objects")

    case File.ls(path) do
      {:ok, names} ->
        {:ok,
         names
         |> Enum.filter(&Regex.match?(~r/^(message|node)-[a-f0-9]{64}\.json$/, &1))
         |> Enum.map(&Path.join(path, &1))}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:conversation_read_failed, reason}}
    end
  end

  defp files(id, opts) do
    with {:ok, revisions} <- revision_files(id, opts),
         {:ok, objects} <- object_files(id, opts),
         do: {:ok, revisions ++ objects}
  end

  defp sizes(files) do
    Alto.Result.traverse(files, fn path ->
      case File.stat(path) do
        {:ok, %{type: :regular, size: size}} -> {:ok, {path, size}}
        _ -> {:error, {:conversation_read_failed, path}}
      end
    end)
  end

  defp valid_hash?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp hash(encoded), do: :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)

  defp object_path(id, {kind, ref}, opts),
    do: Path.join([dir(id, opts), "objects", "#{kind}-#{ref}.json"])

  defp dir(id, opts), do: Path.join([Session.dir(opts), "conversations", id])
  defp unwrap({:ok, value}), do: value
  defp unwrap(error), do: error
end
