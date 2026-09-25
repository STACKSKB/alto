defmodule Alto.Tools.ProtectPaths do
  @moduledoc "Compose protected workspace paths with a tool taking a `path` argument."

  alias Alto.Tools.Path, as: SafePath

  @doc "Wrap a prepared file tool using the existing input-transform boundary."
  def wrap(tool, paths) when is_list(paths) do
    unless Enum.all?(paths, fn path ->
             is_binary(path) and Path.type(path) == :relative and
               not Enum.any?(Path.split(path), &(&1 == ".."))
           end),
           do: raise(ArgumentError, "protected paths must be workspace-relative")

    Alto.Tools.Transform.wrap(tool, fn arguments, context ->
      with {:ok, resolved} <- SafePath.resolve(arguments["path"], context.cwd),
           {:ok, roots} <- protected_roots(paths, context.cwd) do
        lexical = Path.expand(arguments["path"], context.cwd)

        blocked =
          Enum.any?(roots, fn protected ->
            within?(resolved, protected) or within?(lexical, protected)
          end)

        if blocked, do: {:error, {:protected_path, arguments["path"]}}, else: {:ok, arguments}
      end
    end)
  end

  defp protected_roots(paths, cwd) do
    Alto.Result.reduce(paths, [], fn path, acc ->
      with {:ok, resolved} <- SafePath.resolve(path, cwd),
           do: {:ok, [resolved, Path.expand(path, cwd) | acc]}
    end)
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
