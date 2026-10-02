defmodule UpstreamSkills do
  @moduledoc "Explicit pinned upstream skill reuse; an example, not an Alto skill catalogue."
  @max_skills 8
  @max_bytes 32_000

  @doc "Fetch the entire repository at an exact commit into a new directory. Never executes its files."
  def fetch(source, commit, destination) when is_binary(source) do
    destination = Path.expand(destination)

    with :ok <- revision(commit),
         :ok <- real_path(Path.dirname(destination)),
         :ok <- File.mkdir(destination),
         {:ok, _} <- git(destination, ["init", "--quiet"], :init),
         {:ok, _} <-
           git(destination, ["fetch", "--quiet", "--depth=1", "--", source, commit], :fetch),
         {:ok, _} <- git(destination, ["checkout", "--quiet", "--detach", commit], :checkout),
         :ok <- verify(destination, commit) do
      {:ok, destination}
    end
  end

  @doc "Read only explicitly selected SKILL.md files, preserving their supporting files in the checkout."
  def load(checkout, commit, directories) when is_list(directories) do
    checkout = Path.expand(checkout)

    with true <- length(directories) in 1..@max_skills or {:error, :skill_count_limit},
         :ok <- verify(checkout, commit) do
      Alto.Result.traverse(directories, &read_skill(checkout, &1))
    end
  end

  @doc "Build ordinary prompt fragments for the selected skills; does not register tools or grant authority."
  def prompt(skills) do
    Alto.Prompt.render(
      Enum.flat_map(skills, fn skill ->
        [
          "Selected upstream skill: #{skill.path}\nSupporting files: #{skill.directory}",
          String.replace(skill.instructions, "{baseDir}", skill.directory)
        ]
      end)
    )
  end

  defp read_skill(checkout, directory) when is_binary(directory) do
    parts = String.split(directory, "/")

    if Path.type(directory) == :relative and
         Enum.all?(parts, &(&1 not in ["", ".", "..", ".git"])) and
         not String.contains?(directory, ["\\", "\0", "\n", "\r"]) do
      directory = Path.join(checkout, directory)
      path = Path.join(directory, "SKILL.md")

      with :ok <- real_path(directory),
           {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.lstat(path),
           {:ok, instructions} <- Alto.BoundedFile.range(path, 0, @max_bytes + 1),
           true <- byte_size(instructions) <= @max_bytes or {:error, :skill_too_large},
           true <- String.valid?(instructions) or {:error, :skill_not_utf8} do
        {:ok, %{path: path, directory: directory, instructions: instructions}}
      else
        {:ok, %{size: size}} when size > @max_bytes -> {:error, :skill_too_large}
        {:ok, _} -> {:error, :skill_not_regular}
        error -> error
      end
    else
      {:error, :unsafe_skill_path}
    end
  end

  defp read_skill(_, _), do: {:error, :unsafe_skill_path}

  defp verify(checkout, commit) do
    with :ok <- revision(commit),
         :ok <- real_path(checkout),
         {:ok, top} <- git(checkout, ["rev-parse", "--show-toplevel"], :verify),
         true <- String.trim(top) == checkout or {:error, :not_checkout_root},
         {:ok, actual} <- git(checkout, ["rev-parse", "HEAD"], :verify),
         true <- String.trim(actual) == commit or {:error, :revision_mismatch},
         {:ok, tracked} <- git(checkout, ["ls-files", "--stage", "-z"], :verify),
         true <- regular_tree?(tracked) or {:error, :unsupported_repository_entries},
         {:ok, flags} <- git(checkout, ["ls-files", "-v", "-z"], :verify),
         true <- ordinary_index?(flags) or {:error, :unsupported_index_flags},
         {:ok, dirty} <-
           git(
             checkout,
             ["status", "--porcelain", "--untracked-files=all", "--ignored=matching", "-z"],
             :verify
           ),
         true <- dirty == "" or {:error, :dirty_checkout} do
      :ok
    end
  end

  defp regular_tree?(entries),
    do:
      entries
      |> String.split("\0", trim: true)
      |> Enum.all?(&String.starts_with?(&1, ["100644 ", "100755 "]))

  defp ordinary_index?(entries),
    do: entries |> String.split("\0", trim: true) |> Enum.all?(&String.starts_with?(&1, "H "))

  defp revision(commit) do
    if is_binary(commit) and Regex.match?(~r/\A[0-9a-f]{40}\z/, commit),
      do: :ok,
      else: {:error, :full_commit_required}
  end

  defp real_path(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        if Path.dirname(path) == path, do: :ok, else: real_path(Path.dirname(path))

      {:ok, _} ->
        {:error, :unsafe_checkout_path}

      {:error, _} = error ->
        error
    end
  end

  defp git(directory, args, stage) do
    # Ignore global hooks/filters, avoid prompting, and never return Git output
    # on errors: remote URLs can contain credentials.
    env = [
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_COUNT", "0"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_DIR", nil},
      {"GIT_WORK_TREE", nil},
      {"GIT_INDEX_FILE", nil},
      {"GIT_OBJECT_DIRECTORY", nil},
      {"GIT_ALTERNATE_OBJECT_DIRECTORIES", nil},
      {"GIT_COMMON_DIR", nil}
    ]

    case System.cmd(
           "git",
           [
             "-c",
             "core.hooksPath=/dev/null",
             "-c",
             "submodule.recurse=false",
             "-c",
             "core.fsmonitor=false",
             "-C",
             directory | args
           ],
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:git_failed, stage, status}}
    end
  rescue
    _error in ErlangError -> {:error, {:git_unavailable, stage}}
  end
end
