defmodule Alto.Session.ChildIndex do
  @moduledoc false
  use GenServer

  # A disposable projection, never execution truth. Logs remain authoritative;
  # fingerprints invalidate replaced/changed files and missing entries are pruned.
  # Bound both directory count and the scan itself (in Children).
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def headers(dir, names), do: GenServer.call(__MODULE__, {dir, names}, :infinity)

  @impl true
  def init(_), do: {:ok, []}

  @impl true
  def handle_call({dir, names}, _from, directories) do
    previous =
      case List.keyfind(directories, dir, 0) do
        {^dir, entries} -> entries
        _ -> load(dir)
      end

    entries =
      Map.new(names, fn name ->
        path = Path.join(dir, name)

        case File.lstat(path, time: :posix) do
          {:ok, %{type: :regular} = stat} ->
            stamp = {stat.major_device, stat.inode, stat.size, stat.mtime, stat.ctime}

            record =
              case Map.get(previous, name) do
                {^stamp, record} when not is_nil(record) -> record
                _ -> Alto.Session.Children.header(path)
              end

            {name, {stamp, record}}

          _ ->
            {name, {nil, nil}}
        end
      end)

    headers =
      Enum.flat_map(names, fn name ->
        case entries[name] do
          {_, %{"type" => "started", "subagent" => true} = record} ->
            [%{id: Path.rootname(name), started: record}]

          _ ->
            []
        end
      end)

    if entries != previous, do: save(dir, entries)
    {:reply, headers, Enum.take([{dir, entries} | List.keydelete(directories, dir, 0)], 4)}
  end

  defp load(dir) do
    with {:ok, bytes} <- Alto.BoundedFile.read(cache_path(dir), 4_000_000),
         {:ok, %{"v" => 1, "entries" => entries}} when is_map(entries) <- JSON.decode(bytes),
         true <- map_size(entries) <= 4096 do
      Enum.reduce(entries, %{}, fn
        {name, [stamp, record]}, acc
        when is_binary(name) and is_list(stamp) and length(stamp) == 5 ->
          if is_map(record),
            do: Map.put(acc, name, {List.to_tuple(stamp), Alto.Retained.detach(record)}),
            else: acc

        _, acc ->
          acc
      end)
    else
      _ -> %{}
    end
  end

  defp save(dir, entries) do
    values =
      Map.new(entries, fn {name, {stamp, record}} ->
        {name, [if(is_tuple(stamp), do: Tuple.to_list(stamp)), record]}
      end)

    # A failed/missing cache is harmless; the next scan rebuilds it from logs.
    Alto.Storage.write_json(cache_path(dir), %{"v" => 1, "entries" => values}, 4_000_000)
  end

  defp cache_path(dir), do: Path.join([dir, ".cache", "children.json"])
end
