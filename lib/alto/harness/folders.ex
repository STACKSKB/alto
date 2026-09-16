defmodule Alto.Harness.Folders do
  @moduledoc "Bounded folder suggestions resolved on the host that owns the workspace."

  def complete(path, base) when is_binary(path) and is_binary(base) do
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
          |> Enum.take(50)
          |> Enum.map(&(&1 <> "/"))

        {:ok, folders}
      end
    else
      {:error, :invalid_workspace_path}
    end
  end

  def complete(_, _), do: {:error, :invalid_workspace_path}

  defp valid?(path),
    do:
      byte_size(path) <= 4096 and String.valid?(path) and
        not Regex.match?(~r/[\x00-\x1F\x7F]/u, path)
end
