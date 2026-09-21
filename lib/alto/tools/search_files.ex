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
  @options_schema [
    max_query_bytes: [type: :pos_integer, default: @max_query_bytes],
    max_files: [type: :pos_integer, default: @max_files],
    max_entries: [type: :pos_integer, default: @max_entries],
    max_file_bytes: [type: :pos_integer, default: @max_file_bytes],
    max_matches: [type: :pos_integer, default: @max_matches],
    max_line_graphemes: [type: :pos_integer, default: @max_line_graphemes],
    excluded_directories: [
      type: {:list, :string},
      default: [".git", "_build", "deps", "node_modules"]
    ]
  ]

  @impl true
  def name(_opts \\ []), do: :search_files

  @impl true
  def schema(opts \\ []) when is_list(opts) do
    limits = validate_options!(opts)

    %{
      description:
        "Recursively search workspace text files for a literal string. The search is bounded and skips common generated directories.",
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            minLength: 1,
            maxLength: limits.max_query_bytes,
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
  def execution_mode(_opts \\ []), do: :parallel

  @impl true
  def approval(_opts \\ []), do: :never

  @impl true
  def run(arguments, %Context{} = context, opts \\ []) do
    query = Map.get(arguments, "query")
    path = Map.get(arguments, "path", ".")
    case_sensitive? = Map.get(arguments, "case_sensitive", true)

    with :ok <- validate_case_sensitive(case_sensitive?),
         {:ok, backend, backend_opts} <- resolve_backend(opts),
         :ok <- validate_query(query, query_limits(backend_opts)),
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
        opts
      ) do
    limits = if is_map(opts), do: opts, else: validate_options!(opts)

    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, stat} <- File.lstat(resolved),
         {:ok, state} <-
           search(resolved, stat.type, query, case_sensitive?, context.cwd, limits) do
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

      if backend == __MODULE__ do
        with {:ok, limits} <- validate_options(unknown), do: {:ok, backend, limits}
      else
        normalize_backend(backend)
      end
    else
      {:error, {:invalid_search_options, opts}}
    end
  end

  defp resolve_backend(opts), do: {:error, {:invalid_search_options, opts}}

  defp query_limits(%{max_query_bytes: _} = limits), do: limits
  defp query_limits(_), do: %{max_query_bytes: @max_query_bytes}

  defp normalize_backend({module, opts}) when is_atom(module) and is_list(opts) do
    validate_backend(module, opts)
  end

  defp normalize_backend(module) when is_atom(module), do: validate_backend(module, [])
  defp normalize_backend(backend), do: {:error, {:invalid_search_backend, backend}}

  defp validate_backend(module, opts) do
    if Alto.Capabilities.implements?(module, Alto.Search.Backend) and Keyword.keyword?(opts) do
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

  defp validate_query(query, limits) do
    cond do
      not is_binary(query) or query == "" ->
        {:error, :query_must_be_nonempty}

      byte_size(query) > limits.max_query_bytes ->
        {:error, {:query_too_large, limits.max_query_bytes}}

      not String.valid?(query) ->
        {:error, :query_must_be_utf8}

      true ->
        :ok
    end
  end

  defp validate_case_sensitive(value) when value in [true, false], do: :ok
  defp validate_case_sensitive(_value), do: {:error, :case_sensitive_must_be_boolean}

  defp search(path, type, query, case_sensitive?, cwd, limits)
       when type in [:regular, :directory] do
    state = %{matches: [], scanned_files: 0, visited_entries: 0, truncated: false}
    walk([path], state, query, case_sensitive?, cwd, limits)
  end

  defp search(_path, type, _query, _case_sensitive?, _cwd, _limits),
    do: {:error, {:unsupported_file_type, type}}

  defp walk([], state, _query, _case_sensitive?, _cwd, _limits), do: {:ok, state}

  defp walk(
         queue,
         %{scanned_files: files, visited_entries: entries, matches: matches} = state,
         query,
         case_sensitive?,
         cwd,
         limits
       ) do
    cond do
      files >= limits.max_files or entries >= limits.max_entries or
          length(matches) >= limits.max_matches ->
        {:ok, %{state | truncated: true}}

      true ->
        do_walk(queue, state, query, case_sensitive?, cwd, limits)
    end
  end

  defp do_walk([path | rest], state, query, case_sensitive?, cwd, limits) do
    state = %{state | visited_entries: state.visited_entries + 1}

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} ->
            children =
              names
              |> Enum.reject(&MapSet.member?(limits.excluded_directories, &1))
              |> Enum.sort()
              |> Enum.map(&Path.join(path, &1))

            walk(children ++ rest, state, query, case_sensitive?, cwd, limits)

          {:error, _reason} ->
            walk(rest, state, query, case_sensitive?, cwd, limits)
        end

      {:ok, %{type: :regular, size: size}} when size <= limits.max_file_bytes ->
        next_state = search_file(path, state, query, case_sensitive?, cwd, limits)
        walk(rest, next_state, query, case_sensitive?, cwd, limits)

      {:ok, _stat} ->
        walk(rest, state, query, case_sensitive?, cwd, limits)

      {:error, _reason} ->
        walk(rest, state, query, case_sensitive?, cwd, limits)
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

  defp validate_options(opts) do
    with {:ok, limits} <-
           Alto.Tool.Options.validate(opts, @options_schema, :invalid_search_options),
         do: {:ok, Map.update!(limits, :excluded_directories, &MapSet.new/1)}
  end

  defp validate_options!(opts) do
    case validate_options(opts) do
      {:ok, limits} -> limits
      {:error, reason} -> raise ArgumentError, "invalid search options: #{inspect(reason)}"
    end
  end
end
