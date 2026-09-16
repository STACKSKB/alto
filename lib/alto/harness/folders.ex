defmodule Alto.Harness.Folders do
  @moduledoc "Folder creation and bounded suggestions on the host that owns the workspace."

  @doc "Create a typed folder path (including missing parents) on the workspace host."
  def create(path, base) when is_binary(path) and is_binary(base) do
    if valid?(path) and String.trim(path) != "" do
      root = Path.expand(path, base)

      case File.lstat(root) do
        {:ok, _} ->
          {:error, if(File.dir?(root), do: :folder_already_exists, else: :eexist)}

        {:error, :enoent} ->
          with :ok <- File.mkdir_p(root), do: {:ok, root}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_workspace_path}
    end
  end

  def create(_, _), do: {:error, :invalid_workspace_path}

  def complete(path, base) do
    with {:ok, result} <- suggest(path, base), do: {:ok, result.folders}
  end

  @doc "Bounded display suggestions and the common prefix of every matching directory."
  def suggest(path, base) when is_binary(path) and is_binary(base) do
    if valid?(path) do
      expanded = Path.expand(if(path == "", do: ".", else: path), base)

      {directory, prefix} =
        cond do
          path == "" or String.ends_with?(path, "/") -> {expanded, ""}
          String.starts_with?(path, "~") -> {Path.dirname(expanded), Path.basename(expanded)}
          true -> {Path.expand(Path.dirname(path), base), Path.basename(path)}
        end

      with {:ok, names} <- File.ls(directory) do
        folders =
          names
          |> Stream.filter(&(String.starts_with?(&1, prefix) and valid?(&1)))
          |> Stream.reject(
            &(String.starts_with?(&1, ".") and not String.starts_with?(prefix, "."))
          )
          |> Stream.map(&Path.join(directory, &1))
          |> Stream.filter(&File.dir?/1)
          |> Enum.sort()
          |> Enum.map(&(&1 <> "/"))

        {:ok, %{folders: Enum.take(folders, 50), completion: common_prefix(folders)}}
      end
    else
      {:error, :invalid_workspace_path}
    end
  end

  def suggest(_, _), do: {:error, :invalid_workspace_path}

  @doc false
  def common_prefix([]), do: nil

  def common_prefix(paths) do
    # Sorted endpoints determine the prefix, including matches beyond the display limit.
    {first, last} = Enum.min_max(paths)

    Enum.zip(String.codepoints(first), String.codepoints(last))
    |> Enum.take_while(fn {left, right} -> left == right end)
    |> Enum.map_join(fn {character, _} -> character end)
  end

  defp valid?(path),
    do:
      byte_size(path) <= 4096 and String.valid?(path) and
        not Regex.match?(~r/[\x00-\x1F\x7F]/u, path)
end
