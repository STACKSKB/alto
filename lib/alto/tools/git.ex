defmodule Alto.Tools.Git do
  @moduledoc false

  alias Alto.Command

  @spec run([String.t()], Alto.Tool.context(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(args, %{} = context, opts) do
    with {:ok, prepared} <- prepare(args, context, opts),
         {:ok, result} <- Command.execute(prepared) do
      normalize_result(result)
    end
  end

  def prepare(args, context, opts) do
    command = %{
      "program" => Keyword.get(opts, :executable, "git"),
      "args" => command_args(args, opts),
      "timeout_ms" => Keyword.get(opts, :timeout_ms, 30_000),
      "max_output_bytes" =>
        Keyword.get(opts, :max_output_bytes, Alto.Command.default_output_bytes())
    }

    Command.prepare(command, context, Keyword.take(opts, [:executor, :policy]))
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
  defp normalize_result(%{truncated: true}), do: {:error, :git_output_limit}
  defp normalize_result(%{exit_status: 0} = result), do: {:ok, result}

  defp normalize_result(%{exit_status: status, output: output}),
    do: {:error, {:git_failed, status, output}}

  defp normalize_result(result), do: {:error, {:git_failed, result}}
end

defmodule Alto.Tools.GitInspect do
  @moduledoc "Bounded, read-only access to the installed Git CLI."

  use Alto.Tool, name: :git_inspect, execution_mode: :parallel, approval: :never, arguments: true

  alias Alto.Tools.Git

  @actions ~w(status diff log show branches blame)

  @impl true
  def arguments(_opts) do
    {"Inspect repository status, diffs, history, refs, or blame through Git.",
     [
       action: [type: {:in, @actions}, required: true],
       ref: [type: :string, doc: "Revision for show, or starting revision for log."],
       path: [type: :string, doc: "Optional repository-relative literal path."],
       staged: [type: :boolean, default: false, doc: "For diff, inspect staged changes."],
       limit: [type: {:in, 1..100}, default: 20],
       line_start: [type: :pos_integer],
       line_end: [type: :pos_integer]
     ]}
  end

  @impl true
  def run(arguments, %{} = context, opts \\ []) do
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
    base = ["diff"] ++ if(input["staged"], do: ["--staged"], else: [])
    append_path(base, Map.get(input, "path"))
  end

  defp args(%{"action" => "log"} = input) do
    with {:ok, base} <-
           optional_ref(
             ["log", "--decorate", "--oneline", "-n", Integer.to_string(input["limit"])],
             input
           ),
         do: append_path(base, input["path"])
  end

  defp args(%{"action" => "show", "ref" => ref} = input) do
    with {:ok, ref} <- Git.ref(ref),
         do: append_path(["show", "--stat", "--patch", ref], Map.get(input, "path"))
  end

  defp args(%{"action" => "blame", "path" => path} = input) do
    with {:ok, path} <- Git.pathspec(path),
         {:ok, lines} <- blame_lines(input) do
      {:ok, ["blame"] ++ lines ++ ["--", path]}
    end
  end

  defp args(%{"action" => action}),
    do: {:error, {:missing_git_argument, action}}

  defp optional_ref(args, %{"ref" => ref}) do
    with {:ok, ref} <- Git.ref(ref), do: {:ok, args ++ [ref]}
  end

  defp optional_ref(args, _input), do: {:ok, args}

  defp append_path(args, nil), do: {:ok, args}

  defp append_path(args, path) do
    with {:ok, path} <- Git.pathspec(path), do: {:ok, args ++ ["--", path]}
  end

  defp blame_lines(%{"line_start" => first, "line_end" => last}) when last >= first,
    do: {:ok, ["-L", "#{first},#{last}"]}

  defp blame_lines(%{"line_start" => _}), do: {:error, :invalid_blame_range}
  defp blame_lines(%{"line_end" => _}), do: {:error, :invalid_blame_range}
  defp blame_lines(_), do: {:ok, []}
end

defmodule Alto.Tools.GitMutate do
  @moduledoc "Narrow, approval-required mutations through the installed Git CLI."

  use Alto.Tool,
    name: :git_mutate,
    execution_mode: :exclusive,
    approval: :required,
    arguments: true

  alias Alto.Tool.Arguments
  alias Alto.Command
  alias Alto.Tools.Git

  @actions ~w(stage unstage commit create_branch switch_branch)

  @impl true
  def arguments(_opts) do
    {"Stage files, unstage files, commit, create a branch, or switch branches through Git. Every call requires approval.",
     [
       action: [type: {:in, @actions}, required: true],
       paths: [type: Arguments.list(:string, 1, 200)],
       message: [type: Arguments.text(1, 10_000)],
       branch: [type: Arguments.text(1, 256)]
     ]}
  end

  @impl true
  def prepare(arguments, %{} = context, opts \\ []) do
    with {:ok, args} <- args(arguments),
         {:ok, prepared} <- Git.prepare(args, context, opts) do
      {:ok, prepared, prepared.approval_details}
    end
  end

  @impl true
  def run(prepared, %{}, _opts \\ []) do
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

  defp args(%{"action" => "commit", "message" => message}),
    do: {:ok, ["commit", "-m", message]}

  defp args(%{"action" => "create_branch", "branch" => branch}) do
    with {:ok, branch} <- Git.ref(branch), do: {:ok, ["switch", "-c", branch]}
  end

  defp args(%{"action" => "switch_branch", "branch" => branch}) do
    with {:ok, branch} <- Git.ref(branch), do: {:ok, ["switch", branch]}
  end

  defp args(%{"action" => action}),
    do: {:error, {:missing_git_argument, action}}

  defp path_args(prefix, paths) do
    with {:ok, safe} <- Alto.Result.traverse(paths, &Git.pathspec/1) do
      {:ok, prefix ++ ["--" | safe]}
    end
  end
end
