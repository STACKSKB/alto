defmodule Alto.Tools.Git do
  @moduledoc false

  alias Alto.Command
  alias Alto.Command.Invocation
  alias Alto.Tool.Context

  @spec run([String.t()], Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(args, %Context{} = context, opts) do
    command = %{
      "program" => Keyword.get(opts, :executable, "git"),
      "args" => command_args(args, opts),
      "timeout_ms" => Keyword.get(opts, :timeout_ms, 30_000),
      "max_output_bytes" =>
        Keyword.get(opts, :max_output_bytes, min(64_000, Invocation.max_output_bytes()))
    }

    with {:ok, result} <- Command.run(command, context, Keyword.take(opts, [:executor, :policy])) do
      normalize_result(result)
    end
  end

  defp command_args(args, opts) do
    global = ["--no-pager", "-c", "color.ui=false", "-c", "core.quotepath=false"]

    if Keyword.get(opts, :read_only, false) do
      # Keep read-only inspection independent of repository configuration that
      # can launch helpers or write caches. The command-specific diff flags
      # below disable the remaining external diff/text conversion paths.
      global ++
        [
          "--no-optional-locks",
          "-c",
          "core.fsmonitor=false",
          "-c",
          "core.untrackedCache=false",
          "-c",
          "diff.external=",
          "-c",
          "interactive.diffFilter="
        ] ++ args
    else
      global ++ args
    end
  end

  @spec ref(term()) :: {:ok, String.t()} | {:error, term()}
  def ref(value) when is_binary(value) and value != "" and byte_size(value) <= 256 do
    if String.starts_with?(value, "-") or String.contains?(value, ["\0", "\n", "\r"]) do
      {:error, {:invalid_git_ref, value}}
    else
      {:ok, value}
    end
  end

  def ref(value), do: {:error, {:invalid_git_ref, value}}

  @spec pathspec(term()) :: {:ok, String.t()} | {:error, term()}
  def pathspec(value) when is_binary(value) and value != "" do
    if Path.type(value) == :absolute or ".." in Path.split(value) or
         String.contains?(value, ["\0", "\n", "\r"]) do
      {:error, {:invalid_git_path, value}}
    else
      # Literal pathspecs prevent ':()', globs, and attributes from widening a
      # model-selected target. Git still handles a deleted relative path.
      {:ok, ":(top,literal)" <> value}
    end
  end

  def pathspec(value), do: {:error, {:invalid_git_path, value}}

  defp normalize_result(%{termination: :timeout}), do: {:error, :git_timeout}
  defp normalize_result(%{termination: :output_limit}), do: {:error, :git_output_limit}
  defp normalize_result(%{exit_status: 0} = result), do: {:ok, result}

  defp normalize_result(%{exit_status: status, output: output}),
    do: {:error, {:git_failed, status, output}}

  defp normalize_result(result), do: {:error, {:git_failed, result}}
end

defmodule Alto.Tools.GitInspect do
  @moduledoc "Bounded, read-only access to the installed Git CLI."

  @behaviour Alto.Tool

  alias Alto.Tool.Context
  alias Alto.Tools.Git

  @actions ~w(status diff log show branches blame)

  @impl true
  def name, do: :git_inspect

  @impl true
  def schema do
    %{
      description: "Inspect repository status, diffs, history, refs, or blame through Git.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{type: "string", enum: @actions},
          ref: %{type: "string", description: "Revision for show, or starting revision for log."},
          path: %{type: "string", description: "Optional repository-relative literal path."},
          staged: %{type: "boolean", description: "For diff, inspect the staged changes."},
          limit: %{type: "integer", minimum: 1, maximum: 100},
          line_start: %{type: "integer", minimum: 1},
          line_end: %{type: "integer", minimum: 1}
        },
        required: ["action"],
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
    with {:ok, args} <- args(arguments) do
      Git.run(inspect_args(args), context, Keyword.put(opts, :read_only, true))
    end
  end

  defp inspect_args([action | rest]) when action in ["diff", "show"],
    do: [action, "--no-ext-diff", "--no-textconv" | rest]

  defp inspect_args(["blame" | rest]), do: ["blame", "--no-textconv" | rest]
  defp inspect_args(args), do: args

  defp args(%{"action" => "status"}), do: {:ok, ["status", "--short", "--branch"]}
  defp args(%{"action" => "branches"}), do: {:ok, ["branch", "--all", "--verbose", "--no-abbrev"]}

  defp args(%{"action" => "diff"} = input) do
    base = ["diff"] ++ if(Map.get(input, "staged", false), do: ["--staged"], else: [])
    append_path(base, Map.get(input, "path"))
  end

  defp args(%{"action" => "log"} = input) do
    limit = Map.get(input, "limit", 20)

    if is_integer(limit) and limit in 1..100 do
      with {:ok, base} <-
             optional_ref(
               ["log", "--decorate", "--oneline", "-n", Integer.to_string(limit)],
               input
             ),
           {:ok, result} <- append_path(base, Map.get(input, "path")) do
        {:ok, result}
      end
    else
      {:error, {:invalid_git_limit, limit}}
    end
  end

  defp args(%{"action" => "show", "ref" => ref} = input) do
    with {:ok, ref} <- Git.ref(ref),
         {:ok, result} <- append_path(["show", "--stat", "--patch", ref], Map.get(input, "path")) do
      {:ok, result}
    end
  end

  defp args(%{"action" => "blame", "path" => path} = input) do
    with {:ok, path} <- Git.pathspec(path),
         {:ok, lines} <- blame_lines(input) do
      {:ok, ["blame"] ++ lines ++ ["--", path]}
    end
  end

  defp args(%{"action" => action}) when action in @actions,
    do: {:error, {:missing_git_argument, action}}

  defp args(%{"action" => action}), do: {:error, {:unknown_git_action, action}}
  defp args(_input), do: {:error, :git_action_required}

  defp optional_ref(args, %{"ref" => ref}) do
    with {:ok, ref} <- Git.ref(ref), do: {:ok, args ++ [ref]}
  end

  defp optional_ref(args, _input), do: {:ok, args}

  defp append_path(args, nil), do: {:ok, args}

  defp append_path(args, path) do
    with {:ok, path} <- Git.pathspec(path), do: {:ok, args ++ ["--", path]}
  end

  defp blame_lines(%{"line_start" => first, "line_end" => last})
       when is_integer(first) and is_integer(last) and first > 0 and last >= first,
       do: {:ok, ["-L", "#{first},#{last}"]}

  defp blame_lines(input) do
    if Map.has_key?(input, "line_start") or Map.has_key?(input, "line_end") do
      {:error, :invalid_blame_range}
    else
      {:ok, []}
    end
  end
end

defmodule Alto.Tools.GitMutate do
  @moduledoc "Narrow, approval-required mutations through the installed Git CLI."

  @behaviour Alto.Tool

  alias Alto.Command
  alias Alto.Tool.Context
  alias Alto.Tools.Git

  @actions ~w(stage unstage commit create_branch switch_branch)

  @impl true
  def name, do: :git_mutate

  @impl true
  def schema do
    %{
      description:
        "Stage files, unstage files, commit, create a branch, or switch branches through Git. Every call requires approval.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{type: "string", enum: @actions},
          paths: %{type: "array", items: %{type: "string"}, minItems: 1, maxItems: 200},
          message: %{type: "string", minLength: 1, maxLength: 10_000},
          branch: %{type: "string", minLength: 1, maxLength: 256}
        },
        required: ["action"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def execution_mode, do: :exclusive

  @impl true
  def approval, do: :required

  @impl true
  def prepare(arguments, %Context{} = context), do: prepare(arguments, context, [])

  @impl true
  def prepare(arguments, %Context{} = context, opts) do
    with {:ok, args} <- args(arguments),
         {:ok, prepared} <-
           Command.prepare(command(args, opts), context, Keyword.take(opts, [:executor, :policy])) do
      {:ok, prepared, prepared.approval_details}
    end
  end

  @impl true
  def run_prepared(prepared, %Context{}), do: run_prepared(prepared)

  @impl true
  def run_prepared(prepared, %Context{}, _opts), do: run_prepared(prepared)

  defp run_prepared(prepared) do
    case Command.execute(prepared) do
      {:ok, %{termination: :timeout}} ->
        {:unknown, :git_timeout}

      {:ok, %{termination: :output_limit}} ->
        {:unknown, :git_output_limit}

      {:ok, %{exit_status: 0} = result} ->
        {:ok, result}

      {:ok, %{exit_status: status} = result} when is_integer(status) ->
        {:error, {:git_failed, status, Map.get(result, :output, "")}}

      {:ok, result} ->
        {:unknown, {:git_ambiguous_result, result}}

      {:error, reason} ->
        {:unknown, {:git_execution_uncertain, reason}}

      other ->
        {:unknown, {:git_ambiguous_result, other}}
    end
  end

  defp args(%{"action" => "stage", "paths" => paths}), do: path_args(["add"], paths)

  defp args(%{"action" => "unstage", "paths" => paths}),
    do: path_args(["restore", "--staged"], paths)

  defp args(%{"action" => "commit", "message" => message})
       when is_binary(message) and message != "" and byte_size(message) <= 10_000,
       do: {:ok, ["commit", "-m", message]}

  defp args(%{"action" => "create_branch", "branch" => branch}) do
    with {:ok, branch} <- Git.ref(branch), do: {:ok, ["switch", "-c", branch]}
  end

  defp args(%{"action" => "switch_branch", "branch" => branch}) do
    with {:ok, branch} <- Git.ref(branch), do: {:ok, ["switch", branch]}
  end

  defp args(%{"action" => action}) when action in @actions,
    do: {:error, {:missing_git_argument, action}}

  defp args(%{"action" => action}), do: {:error, {:unknown_git_action, action}}
  defp args(_input), do: {:error, :git_action_required}

  defp path_args(prefix, paths) when is_list(paths) and paths != [] and length(paths) <= 200 do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case Git.pathspec(path) do
        {:ok, safe} -> {:cont, {:ok, [safe | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, safe} -> {:ok, prefix ++ ["--" | Enum.reverse(safe)]}
      error -> error
    end
  end

  defp path_args(_prefix, paths), do: {:error, {:invalid_git_paths, paths}}

  defp command(args, opts) do
    %{
      "program" => Keyword.get(opts, :executable, "git"),
      "args" => ["--no-pager", "-c", "color.ui=false", "-c", "core.quotepath=false" | args],
      "timeout_ms" => Keyword.get(opts, :timeout_ms, 30_000),
      "max_output_bytes" => Keyword.get(opts, :max_output_bytes, 64_000)
    }
  end
end
