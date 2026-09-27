defmodule Alto.Tools.SearchFiles do
  @moduledoc "Bounded, workspace-confined recursive literal text search."

  use Alto.Tool, name: :search_files, execution_mode: :parallel, approval: :never, arguments: true
  alias Alto.Tool.Arguments

  alias Alto.Tool.Context
  alias Alto.Tools.Path, as: SafePath

  @impl true
  def options,
    do: %{
      backend: nil,
      max_query_bytes: 1_024,
      max_files: 2_000,
      max_entries: 10_000,
      max_file_bytes: 1_000_000,
      max_matches: 100,
      max_line_graphemes: 300,
      excluded_directories: MapSet.new([".git", "_build", "deps", "node_modules"])
    }

  @impl true
  def arguments(opts) do
    {"Recursively search workspace text files for a literal string. The search is bounded and skips common generated directories.",
     [
       query: [type: Arguments.text(1, opts.max_query_bytes), required: true],
       path: [type: :string, default: "."],
       case_sensitive: [type: :boolean, default: true]
     ]}
  end

  @impl true
  def run(arguments, %Context{} = context, opts \\ []) do
    query = Map.get(arguments, "query")
    path = arguments["path"]
    case_sensitive? = arguments["case_sensitive"]

    with {:ok, output} <-
           search(%{query: query, path: path, case_sensitive: case_sensitive?}, context, opts) do
      {:ok, output |> Map.put(:path, path) |> Map.put(:query, query)}
    end
  rescue
    error -> {:error, {:search_backend_exception, error}}
  end

  def search(
        %{query: query, path: path, case_sensitive: case_sensitive?},
        %Context{} = context,
        %{backend: nil} = opts
      ) do
    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, stat} <- File.lstat(resolved),
         {:ok, state} <-
           search(resolved, stat.type, query, case_sensitive?, context.cwd, opts) do
      {:ok,
       %{
         matches: Enum.reverse(state.matches),
         scanned_files: state.scanned_files,
         truncated: state.truncated
       }}
    end
  end

  def search(request, context, %{backend: callback}) do
    case callback do
      fun when is_function(fun, 2) -> fun.(request, context)
      {module, function, extra} -> apply(module, function, [request, context] ++ extra)
    end
  end

  defp search(path, type, query, case_sensitive?, cwd, limits)
       when type in [:regular, :directory] do
    state = %{matches: [], scanned_files: 0, visited_entries: 0, truncated: false}
    walk([path], state, query, case_sensitive?, cwd, limits)
  end

  defp search(_path, type, _query, _case_sensitive?, _cwd, _limits),
    do: {:error, {:unsupported_file_type, type}}

  defp walk([], state, _query, _case_sensitive?, _cwd, _limits), do: {:ok, state}

  defp walk(
         _queue,
         %{scanned_files: files, visited_entries: entries, matches: matches} = state,
         _query,
         _case_sensitive?,
         _cwd,
         limits
       )
       when files >= limits.max_files or entries >= limits.max_entries or
              length(matches) >= limits.max_matches,
       do: {:ok, %{state | truncated: true}}

  defp walk([path | rest], state, query, case_sensitive?, cwd, limits) do
    state = %{state | visited_entries: state.visited_entries + 1}

    {children, state} =
      case File.lstat(path) do
        {:ok, %{type: :directory}} ->
          {directory_children(path, limits.excluded_directories), state}

        {:ok, %{type: :regular, size: size}} when size <= limits.max_file_bytes ->
          {[], search_file(path, state, query, case_sensitive?, cwd, limits)}

        _ ->
          {[], state}
      end

    walk(children ++ rest, state, query, case_sensitive?, cwd, limits)
  end

  defp directory_children(path, excluded) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.reject(&MapSet.member?(excluded, &1))
        |> Enum.sort()
        |> Enum.map(&Path.join(path, &1))

      {:error, _} ->
        []
    end
  end

  defp search_file(path, state, query, case_sensitive?, cwd, limits) do
    state = %{state | scanned_files: state.scanned_files + 1}

    case Alto.BoundedFile.read(path, limits.max_file_bytes) do
      {:ok, content} when is_binary(content) ->
        if String.valid?(content) do
          add_line_matches(content, path, state, query, case_sensitive?, cwd, limits)
        else
          state
        end

      {:error, _reason} ->
        state
    end
  end

  defp add_line_matches(content, path, state, query, case_sensitive?, cwd, limits) do
    comparable_query = compare_text(query, case_sensitive?)
    relative_path = Path.relative_to(path, cwd)

    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while(state, fn {line, line_number}, acc ->
      if length(acc.matches) >= limits.max_matches do
        {:halt, %{acc | truncated: true}}
      else
        if String.contains?(compare_text(line, case_sensitive?), comparable_query) do
          match = %{
            path: relative_path,
            line: line_number,
            text: truncate_line(line, limits.max_line_graphemes)
          }

          {:cont, %{acc | matches: [match | acc.matches]}}
        else
          {:cont, acc}
        end
      end
    end)
  end

  defp compare_text(text, true), do: text
  defp compare_text(text, false), do: String.downcase(text)

  defp truncate_line(line, limit) do
    {prefix, rest} = String.split_at(line, limit)
    if rest == "", do: prefix, else: prefix <> "…"
  end
end
