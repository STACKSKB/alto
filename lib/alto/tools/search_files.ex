defmodule Alto.Tools.SearchFiles do
  @moduledoc "Bounded, workspace-confined recursive literal text search."

  @behaviour Alto.Tool
  @behaviour Alto.Search.Backend

  alias Alto.Tool.Context
  alias Alto.Tools.Path, as: SafePath

  @max_query_bytes 1_024
  @max_files 2_000
  @max_entries 10_000
  @max_file_bytes 1_000_000
  @max_matches 100
  @max_line_graphemes 300
  @excluded_directories MapSet.new([".git", "_build", "deps", "node_modules"])

  @impl true
  def name, do: :search_files

  @impl true
  def schema do
    %{
      description:
        "Recursively search workspace text files for a literal string. The search is bounded and skips common generated directories.",
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            minLength: 1,
            maxLength: @max_query_bytes,
            description: "Literal text to find; this is not a regular expression."
          },
          path: %{
            type: "string",
            description: "File or directory to search; defaults to the workspace root."
          },
          case_sensitive: %{
            type: "boolean",
            description: "Whether letter case must match; defaults to true."
          }
        },
        required: ["query"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def execution_mode, do: :parallel

  @impl true
  def approval, do: :never

  @impl true
  def run(arguments, %Context{} = context), do: run(arguments, context, [])

  @impl true
  def run(arguments, %Context{} = context, opts) do
    query = Map.get(arguments, "query")
    path = Map.get(arguments, "path", ".")
    case_sensitive? = Map.get(arguments, "case_sensitive", true)

    with :ok <- validate_query(query),
         :ok <- validate_case_sensitive(case_sensitive?),
         {:ok, backend, backend_opts} <- resolve_backend(opts),
         result <-
           backend.search(
             %{query: query, path: path, case_sensitive: case_sensitive?},
             context,
             backend_opts
           ),
         {:ok, output} <- normalize_backend_result(result, backend) do
      {:ok, output |> Map.put(:path, path) |> Map.put(:query, query)}
    end
  rescue
    error -> {:error, {:search_backend_exception, error}}
  end

  @impl Alto.Search.Backend
  def search(
        %{query: query, path: path, case_sensitive: case_sensitive?},
        %Context{} = context,
        _opts
      ) do
    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, stat} <- File.lstat(resolved),
         {:ok, state} <-
           search(resolved, stat.type, query, case_sensitive?, context.cwd) do
      {:ok,
       %{
         matches: Enum.reverse(state.matches),
         scanned_files: state.scanned_files,
         truncated: state.truncated
       }}
    end
  end

  defp resolve_backend(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {backend, unknown} = Keyword.pop(opts, :backend, __MODULE__)

      if unknown == [] do
        normalize_backend(backend)
      else
        {:error, {:unknown_search_options, Keyword.keys(unknown)}}
      end
    else
      {:error, {:invalid_search_options, opts}}
    end
  end

  defp resolve_backend(opts), do: {:error, {:invalid_search_options, opts}}

  defp normalize_backend({module, opts}) when is_atom(module) and is_list(opts) do
    validate_backend(module, opts)
  end

  defp normalize_backend(module) when is_atom(module), do: validate_backend(module, [])
  defp normalize_backend(backend), do: {:error, {:invalid_search_backend, backend}}

  defp validate_backend(module, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :search, 3) and
         Keyword.keyword?(opts) do
      {:ok, module, opts}
    else
      {:error, {:invalid_search_backend, {module, opts}}}
    end
  end

  defp normalize_backend_result({:ok, result}, _backend) when is_map(result),
    do: {:ok, result}

  defp normalize_backend_result({:error, reason}, _backend), do: {:error, reason}

  defp normalize_backend_result(other, backend),
    do: {:error, {:invalid_search_backend_return, backend, other}}

  defp validate_query(query) do
    cond do
      not is_binary(query) or query == "" -> {:error, :query_must_be_nonempty}
      byte_size(query) > @max_query_bytes -> {:error, {:query_too_large, @max_query_bytes}}
      not String.valid?(query) -> {:error, :query_must_be_utf8}
      true -> :ok
    end
  end

  defp validate_case_sensitive(value) when value in [true, false], do: :ok
  defp validate_case_sensitive(_value), do: {:error, :case_sensitive_must_be_boolean}

  defp search(path, :regular, query, case_sensitive?, cwd) do
    walk([path], initial_state(), query, case_sensitive?, cwd)
  end

  defp search(path, :directory, query, case_sensitive?, cwd) do
    walk([path], initial_state(), query, case_sensitive?, cwd)
  end

  defp search(_path, type, _query, _case_sensitive?, _cwd),
    do: {:error, {:unsupported_file_type, type}}

  defp initial_state do
    %{matches: [], scanned_files: 0, visited_entries: 0, truncated: false}
  end

  defp walk([], state, _query, _case_sensitive?, _cwd), do: {:ok, state}

  defp walk(_queue, %{scanned_files: count} = state, _query, _case_sensitive?, _cwd)
       when count >= @max_files,
       do: {:ok, %{state | truncated: true}}

  defp walk(_queue, %{visited_entries: count} = state, _query, _case_sensitive?, _cwd)
       when count >= @max_entries,
       do: {:ok, %{state | truncated: true}}

  defp walk(_queue, %{matches: matches} = state, _query, _case_sensitive?, _cwd)
       when length(matches) >= @max_matches,
       do: {:ok, %{state | truncated: true}}

  defp walk([path | rest], state, query, case_sensitive?, cwd) do
    state = %{state | visited_entries: state.visited_entries + 1}

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} ->
            children =
              names
              |> Enum.reject(&MapSet.member?(@excluded_directories, &1))
              |> Enum.sort()
              |> Enum.map(&Path.join(path, &1))

            walk(children ++ rest, state, query, case_sensitive?, cwd)

          {:error, _reason} ->
            walk(rest, state, query, case_sensitive?, cwd)
        end

      {:ok, %{type: :regular, size: size}} when size <= @max_file_bytes ->
        next_state = search_file(path, state, query, case_sensitive?, cwd)
        walk(rest, next_state, query, case_sensitive?, cwd)

      {:ok, _stat} ->
        walk(rest, state, query, case_sensitive?, cwd)

      {:error, _reason} ->
        walk(rest, state, query, case_sensitive?, cwd)
    end
  end

  defp search_file(path, state, query, case_sensitive?, cwd) do
    state = %{state | scanned_files: state.scanned_files + 1}

    case File.read(path) do
      {:ok, content} when is_binary(content) ->
        if String.valid?(content) do
          add_line_matches(content, path, state, query, case_sensitive?, cwd)
        else
          state
        end

      {:error, _reason} ->
        state
    end
  end

  defp add_line_matches(content, path, state, query, case_sensitive?, cwd) do
    comparable_query = compare_text(query, case_sensitive?)
    relative_path = Path.relative_to(path, cwd)

    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while(state, fn {line, line_number}, acc ->
      if length(acc.matches) >= @max_matches do
        {:halt, %{acc | truncated: true}}
      else
        if String.contains?(compare_text(line, case_sensitive?), comparable_query) do
          match = %{
            path: relative_path,
            line: line_number,
            text: truncate_line(line)
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

  defp truncate_line(line) do
    if String.length(line) > @max_line_graphemes do
      String.slice(line, 0, @max_line_graphemes) <> "…"
    else
      line
    end
  end
end
