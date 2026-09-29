defmodule Alto.Session.Children do
  @moduledoc "Bounded discovery of saved child sessions, independent of the recent-session list."
  alias Alto.Session
  @max_scan 4096
  @max_children 256
  @header_bytes 32_768

  def list(parent, opts \\ []) do
    with :ok <- Session.validate_id(parent),
         {:ok, names} <- filenames(Session.dir(opts)) do
      names =
        Enum.filter(
          names,
          &(String.ends_with?(&1, ".jsonl") and Session.validate_id(Path.rootname(&1)) == :ok)
        )

      headers =
        Alto.Session.ChildIndex.headers(
          Session.dir(opts),
          names |> Enum.sort() |> Enum.take(@max_scan)
        )
        |> Enum.group_by(& &1.started["parent_session_id"])

      {children, truncated} = descend([parent], MapSet.new([parent]), headers, [])

      {:ok,
       %{sessions: Enum.reverse(children), truncated: truncated or length(names) > @max_scan}}
    end
  end

  defp filenames(dir) do
    case File.ls(dir) do
      {:error, :enoent} -> {:ok, []}
      other -> other
    end
  end

  @doc false
  def header(path) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, bytes} <- :file.read(file, @header_bytes),
             [line, _] <- String.split(bytes, "\n", parts: 2),
             {:ok, %{} = record} <- JSON.decode(:binary.copy(line)),
             1 <- record["v"] do
          record
        else
          _ -> nil
        end
      after
        :file.close(file)
      end
    else
      _ -> nil
    end
  end

  defp descend([], _, _, acc), do: {acc, false}

  defp descend([parent | rest], seen, headers, acc) do
    children =
      Enum.filter(
        Map.get(headers, parent, []),
        &(not MapSet.member?(seen, &1.id))
      )

    remaining = @max_children - length(acc)
    kept = Enum.take(children, remaining)
    seen = Enum.reduce(kept, seen, &MapSet.put(&2, &1.id))

    if length(children) > remaining do
      {Enum.reverse(kept) ++ acc, true}
    else
      descend(rest ++ Enum.map(kept, & &1.id), seen, headers, Enum.reverse(kept) ++ acc)
    end
  end
end
