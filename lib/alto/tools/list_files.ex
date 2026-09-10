defmodule Alto.Tools.ListFiles do
  @moduledoc "Bounded, workspace-confined directory listings."

  @behaviour Alto.Tool

  alias Alto.Tool.Context
  alias Alto.Tools.Path, as: SafePath

  @max_entries 500

  @impl true
  def name, do: :list_files

  @impl true
  def schema do
    %{
      description: "List one directory inside the workspace (non-recursive and bounded).",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Directory path; defaults to the workspace root."}
        },
        additionalProperties: false
      }
    }
  end

  @impl true
  def execution_mode, do: :parallel

  @impl true
  def approval, do: :never

  @impl true
  def run(arguments, %Context{} = context) do
    path = Map.get(arguments, "path", ".")

    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, names} <- File.ls(resolved) do
      sorted = Enum.sort(names)
      selected = Enum.take(sorted, @max_entries)

      entries =
        Enum.map(selected, fn name ->
          %{name: name, type: entry_type(Path.join(resolved, name))}
        end)

      {:ok, %{path: path, entries: entries, truncated: length(sorted) > @max_entries}}
    end
  end

  defp entry_type(path) do
    case File.lstat(path) do
      {:ok, %{type: type}} -> type
      {:error, _reason} -> :unknown
    end
  end
end
