defmodule Alto.Tools.ListFiles do
  @moduledoc "Bounded, workspace-confined directory listings."

  @behaviour Alto.Tool

  alias Alto.Tool.Context
  alias Alto.Tools.Path, as: SafePath

  @max_entries 500
  @options_schema [max_entries: [type: :pos_integer, default: @max_entries]]

  @impl true
  def name(_opts \\ []), do: :list_files

  @impl true
  def schema(opts \\ []) when is_list(opts) do
    limits = validate_options!(opts)

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
    |> put_in(
      [:parameters, :properties, :path, :description],
      "Directory path; defaults to the workspace root (up to #{limits.max_entries} entries)."
    )
  end

  @impl true
  def execution_mode(_opts \\ []), do: :parallel

  @impl true
  def approval(_opts \\ []), do: :never

  @impl true
  def run(arguments, %Context{} = context, opts \\ []) do
    path = Map.get(arguments, "path", ".")

    with {:ok, limits} <- validate_options(opts),
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

  defp validate_options(opts),
    do: Alto.Tool.Options.validate(opts, @options_schema, :invalid_list_files_options)

  defp validate_options!(opts), do: Map.new(NimbleOptions.validate!(opts, @options_schema))
end
