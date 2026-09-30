defmodule Alto.Contrib.Tools.ListFiles do
  @moduledoc "Bounded, workspace-confined directory listings."

  use Alto.Tool, name: :list_files, execution_mode: :parallel, approval: :never, arguments: true

  alias Alto.Contrib.Tools.Path, as: SafePath

  @impl true
  def options, do: %{max_entries: 500}

  @impl true
  def arguments(_opts) do
    {"List one directory inside the workspace (non-recursive and bounded).",
     [path: [type: :string, default: ".", doc: "Directory path; defaults to the workspace root."]]}
  end

  @impl true
  def run(arguments, %{} = context, opts \\ []) do
    path = arguments["path"]

    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, names} <- File.ls(resolved) do
      sorted = Enum.sort(names)
      selected = Enum.take(sorted, opts.max_entries)

      entries =
        Enum.map(selected, fn name ->
          %{name: name, type: entry_type(Path.join(resolved, name))}
        end)

      {:ok, %{path: path, entries: entries, truncated: length(sorted) > opts.max_entries}}
    end
  end

  defp entry_type(path) do
    case File.lstat(path) do
      {:ok, %{type: type}} -> type
      {:error, _reason} -> :unknown
    end
  end
end
