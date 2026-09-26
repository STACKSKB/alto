defmodule Alto.Tools.ListFiles do
  @moduledoc "Bounded, workspace-confined directory listings."

  use Alto.Tool, name: :list_files, execution_mode: :parallel, approval: :never

  alias Alto.Tool.Context
  alias Alto.Tools.Path, as: SafePath

  @options_schema [max_entries: [type: :pos_integer, default: 500]]

  @impl true
  def schema(opts \\ []) when is_list(opts) do
    limits = Alto.Tool.Options.validate!(opts, @options_schema)

    Alto.Tool.object_schema(
      "List one directory inside the workspace (non-recursive and bounded).",
      %{
        path: %{
          type: "string",
          description:
            "Directory path; defaults to the workspace root (up to #{limits.max_entries} entries)."
        }
      }
    )
  end

  @impl true
  def run(arguments, %Context{} = context, opts \\ []) do
    path = Map.get(arguments, "path", ".")

    with {:ok, limits} <-
           Alto.Tool.Options.validate(opts, @options_schema, :invalid_list_files_options),
         {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, names} <- File.ls(resolved) do
      sorted = Enum.sort(names)
      selected = Enum.take(sorted, limits.max_entries)

      entries =
        Enum.map(selected, fn name ->
          %{name: name, type: entry_type(Path.join(resolved, name))}
        end)

      {:ok, %{path: path, entries: entries, truncated: length(sorted) > limits.max_entries}}
    end
  end

  defp entry_type(path) do
    case File.lstat(path) do
      {:ok, %{type: type}} -> type
      {:error, _reason} -> :unknown
    end
  end
end
