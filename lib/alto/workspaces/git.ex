defmodule Alto.Workspaces.Git do
  @moduledoc "Bounded independent local Git clones for isolated child workspaces."

  @behaviour Alto.Workspaces.Backend

  alias Alto.Command

  @options_schema NimbleOptions.new!(
                    max_source_bytes: [type: :pos_integer, default: 512 * 1_024 * 1_024],
                    max_files: [type: :pos_integer, default: 20_000],
                    max_checkout_bytes: [type: :pos_integer, default: 128 * 1_024 * 1_024],
                    max_patch_bytes: [type: {:in, 1..1_000_000}, default: 1_000_000],
                    timeout_ms: [type: {:in, 1..120_000}, default: 120_000],
                    layout: [type: {:in, [:clone, :worktree]}, default: :clone],
                    ref: [type: :string, default: "HEAD"],
                    branch: [type: {:or, [:string, nil]}, default: nil]
                  )

  @doc false
  def command(cwd, args, opts \\ []) do
    with {:ok, limits} <- limits(opts), do: git(cwd, args, limits)
  end

  @doc false
  def integration_target(repo, opts \\ []) do
    with {:ok, limits} <- limits(opts),
         {:ok, root, head} <- source_head(repo, limits),
         {:ok, config} <- git(root, ["config", "--includes", "--null", "--list"], limits),
         {:ok, stat} <- File.stat(root) do
      {:ok,
       %{
         "root" => root,
         "head" => head,
         "inode" => stat.inode,
         "device" => stat.major_device,
         "config_sha256" => Base.encode16(:crypto.hash(:sha256, config), case: :lower)
       }}
    end
  end

  @spec snapshot(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(repo, opts \\ []) when is_binary(repo) and is_list(opts) do
    with {:ok, limits} <- limits(opts),
         {:ok, root, _head} <- source_head(repo, limits),
         {:ok, ref} <- Alto.Tools.Git.ref(limits.ref),
         {:ok, commit} <- git(root, ["rev-parse", "--verify", ref <> "^{commit}"], limits),
         commit <- String.trim(commit),
         {:ok, tree} <- git(root, ["rev-parse", "--verify", commit <> "^{tree}"], limits),
         {:ok, _} <- checkout_size(root, commit, limits.max_checkout_bytes, limits),
         :ok <- source_status(root, limits) do
      snapshot = %{"source" => root, "base_commit" => commit, "base_tree" => String.trim(tree)}

      if limits.layout == :worktree do
        with {:ok, common} <- common_dir(root, limits),
             :ok <- validate_branch(root, limits.branch, limits) do
          {:ok, Map.merge(snapshot, %{"common_dir" => common, "branch" => limits.branch})}
        end
      else
        {:ok, snapshot}
      end
    end
  end

  defp source_status(_root, %{layout: :worktree}), do: :ok

  defp source_status(root, limits) do
    with {:ok, status} <-
           git(
             root,
             ["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=all"],
             limits
           ),
         true <- String.trim(status) == "" or {:error, :source_dirty},
         do: :ok
  end

  @spec checkout(map(), Path.t(), keyword()) :: :ok | {:error, term()}
  def checkout(snapshot, destination, opts \\ [])
      when is_map(snapshot) and is_binary(destination) do
    with {:ok, limits} <- limits(opts),
         {:ok, snapshot} <- validate_snapshot(snapshot) do
      if limits.layout == :worktree,
        do: checkout_linked(snapshot, Path.expand(destination), limits),
        else: checkout_clone(snapshot, destination, limits)
    end
  end

  defp checkout_clone(snapshot, destination, limits) do
    root = Path.expand(destination)
    git_dir = root <> ".git"

    with :ok <- ordinary_repository(snapshot["source"]),
         :ok <- bounded_source(snapshot["source"], limits),
         {:ok, _} <-
           checkout_size(
             snapshot["source"],
             snapshot["base_commit"],
             limits.max_checkout_bytes,
             limits
           ),
         :ok <- reject_new_path(root),
         :ok <- reject_new_path(git_dir),
         :ok <- File.mkdir_p(Path.dirname(root)),
         {:ok, _} <-
           git(
             Path.dirname(root),
             [
               "clone",
               "--local",
               "--no-hardlinks",
               "--no-checkout",
               "--separate-git-dir",
               git_dir,
               "--template=/dev/null",
               snapshot["source"],
               root
             ],
             limits
           ),
         :ok <- verify_git_pointer(root, git_dir),
         {:ok, _} <-
           workspace_git(
             root,
             git_dir,
             ["checkout", "--detach", snapshot["base_commit"]],
             limits
           ),
         :ok <- verify_checkout(root, snapshot, limits, git_dir) do
      :ok
    end
  end

  @spec diff(map(), Path.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def diff(snapshot, destination, opts \\ []) when is_map(snapshot) and is_binary(destination) do
    with {:ok, limits} <- limits(opts),
         {:ok, snapshot} <- validate_snapshot(snapshot),
         root <- Path.expand(destination),
         {:ok, git_dir} <- workspace_metadata(root, snapshot, limits),
         true <- File.dir?(root) or {:error, :wrong_workspace},
         :ok <- verify_checkout(root, snapshot, limits, git_dir),
         :ok <- reject_source_filters(root, limits),
         :ok <- bounded_workspace(root, git_dir, limits),
         {:ok, _} <- workspace_git(root, git_dir, ["add", "--all"], limits),
         :ok <- reject_index_gitlinks(root, git_dir, limits),
         {:ok, patch} <-
           workspace_git(
             root,
             git_dir,
             [
               "diff",
               "--cached",
               "--binary",
               "--no-ext-diff",
               "--no-textconv",
               snapshot["base_commit"]
             ],
             limits,
             max_output_bytes: limits.max_patch_bytes
           ) do
      if byte_size(patch) <= limits.max_patch_bytes,
        do: {:ok, patch},
        else: {:error, :patch_too_large}
    end
  end

  @doc false
  def prepare_apply(source, patch_path, patch_sha256, opts \\ []) do
    Alto.Workspaces.GitPatch.prepare(source, patch_path, patch_sha256, opts)
  end

  @doc false
  def verify_apply(source, integration, patch_path, opts \\ []) do
    with true <- get_in(integration, ["target", "root"]) == source do
      Alto.Workspaces.GitPatch.verify(integration, patch_path, opts)
    else
      false -> {:error, :stale_patch_target}
    end
  end

  @doc false
  def apply(source, integration, patch_path, opts \\ []) do
    with true <- get_in(integration, ["target", "root"]) == source do
      Alto.Workspaces.GitPatch.apply(integration, patch_path, opts)
    else
      false -> {:unknown, :stale_patch_target}
    end
  end

  defp limits(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, values} <- NimbleOptions.validate(opts, @options_schema),
           do: {:ok, Map.new(values)}
    else
      {:error, :invalid_workspace_options}
    end
  end

  defp source_head(repo, limits) do
    with {:ok, root} <- repository_root(repo, limits),
         :ok <- bounded_source(root, limits),
         :ok <- reject_source_filters(root, limits),
         {:ok, head} <- git(root, ["rev-parse", "--verify", "HEAD^{commit}"], limits) do
      {:ok, root, String.trim(head)}
    end
  end

  defp bounded_source(root, limits) do
    with {:ok, metadata} <- source_metadata(root, limits),
         :ok <- bounded_tree(metadata, limits.max_source_bytes, limits.max_files),
         false <- File.exists?(Path.join(metadata, "objects/info/alternates")) do
      :ok
    else
      true -> {:error, :alternates_unsupported}
      error -> error
    end
  end

  defp repository_root(repo, limits) do
    root = Path.expand(repo)

    with true <- File.dir?(root) or {:error, :repository_not_found},
         :ok <- reject_symlink_components(root),
         :ok <- repository_layout(root, limits),
         {:ok, reported} <- git(root, ["rev-parse", "--show-toplevel"], limits),
         true <- Path.expand(String.trim(reported)) == root or {:error, :not_repository} do
      {:ok, root}
    end
  end

  defp ordinary_repository(root) do
    case File.lstat(Path.join(root, ".git")) do
      {:ok, %{type: :directory}} -> :ok
      _ -> {:error, :ordinary_repository_required}
    end
  end

  # A source status check can invoke clean/process filters. Reject them before
  # status rather than execute repository-local helper commands during snapshot.
  defp reject_source_filters(root, limits) do
    with {:ok, names} <-
           git(root, ["config", "--includes", "--null", "--name-only", "--list"], limits) do
      if Enum.any?(
           String.split(names, <<0>>, trim: true),
           &String.starts_with?(String.downcase(&1), "filter.")
         ),
         do: {:error, :source_filters_unsupported},
         else: :ok
    end
  end

  defp validate_snapshot(
         %{"source" => source, "base_commit" => commit, "base_tree" => tree} = snapshot
       )
       when map_size(snapshot) in [3, 5] and is_binary(source) and is_binary(commit) and
              is_binary(tree) do
    with true <- valid_snapshot_layout?(snapshot) or {:error, :invalid_snapshot},
         true <- Path.expand(source) == source or {:error, :invalid_snapshot},
         true <- (valid_hex?(commit, 40) and valid_hex?(tree, 40)) or {:error, :invalid_snapshot},
         :ok <- reject_symlink_components(source),
         true <- File.dir?(source) or {:error, :invalid_snapshot} do
      {:ok, snapshot}
    end
  end

  defp validate_snapshot(_), do: {:error, :invalid_snapshot}

  defp valid_snapshot_layout?(snapshot) when map_size(snapshot) == 3, do: true

  defp valid_snapshot_layout?(%{"common_dir" => common, "branch" => branch}),
    do:
      is_binary(common) and Path.type(common) == :absolute and
        (is_nil(branch) or is_binary(branch))

  defp valid_snapshot_layout?(_), do: false

  defp verify_checkout(root, snapshot, limits, git_dir) do
    runner = &workspace_git(root, git_dir, &1, limits)

    with {:ok, head} <- runner.(["rev-parse", "--verify", "HEAD^{commit}"]),
         {:ok, tree} <- runner.(["rev-parse", "--verify", "HEAD^{tree}"]),
         true <- String.trim(head) == snapshot["base_commit"] or {:error, :stale_workspace},
         true <- String.trim(tree) == snapshot["base_tree"] or {:error, :stale_workspace} do
      :ok
    end
  end

  defp reject_index_gitlinks(root, git_dir, limits) do
    with {:ok, output} <- workspace_git(root, git_dir, ["ls-files", "--stage", "-z"], limits) do
      if output
         |> String.split(<<0>>, trim: true)
         |> Enum.any?(fn entry -> String.starts_with?(entry, "160000 ") end) do
        {:error, :submodule_unsupported}
      else
        :ok
      end
    end
  end

  defp verify_git_pointer(root, git_dir) do
    with :ok <- reject_symlink_components(root),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= 4_096 <-
           File.lstat(Path.join(root, ".git")),
         {:ok, pointer} <- File.read(Path.join(root, ".git")),
         true <- String.trim(pointer) == "gitdir: " <> git_dir or {:error, :invalid_git_pointer},
         :ok <- reject_symlink_components(git_dir),
         true <- File.dir?(git_dir) or {:error, :invalid_git_pointer} do
      :ok
    else
      {:ok, _} -> {:error, :invalid_git_pointer}
      {:error, _} = error -> error
    end
  end

  defp checkout_size(root, commit, max, limits) do
    with {:ok, output} <- git(root, ["ls-tree", "-r", "-l", "--full-tree", commit], limits),
         do: parse_tree_sizes(output, max, limits.max_files)
  end

  defp parse_tree_sizes(output, max, max_files) do
    lines = String.split(output, "\n", trim: true)

    if length(lines) > max_files do
      {:error, :checkout_too_large}
    else
      Alto.Result.reduce(lines, 0, fn line, total ->
        case String.split(line, [" ", "\t"], trim: true, parts: 5) do
          ["120000", "blob", _hash, _size, _path] ->
            {:error, :symlink_unsupported}

          [mode, "blob", _hash, size, _path] when mode in ["100644", "100755"] ->
            case Integer.parse(size) do
              {bytes, ""} when total + bytes <= max -> {:ok, total + bytes}
              {_, ""} -> {:error, :checkout_too_large}
              _ -> {:error, :invalid_tree}
            end

          [_mode, "commit", _hash, _size, _path] ->
            {:error, :submodule_unsupported}

          _ ->
            {:error, :invalid_tree}
        end
      end)
    end
  end

  # Bound files Git will stage; ignored caches and build output are not cloned
  # or captured. Removed tracked paths contribute no bytes to the new checkout.
  defp bounded_workspace(root, git_dir, limits) do
    with {:ok, output} <-
           workspace_git(
             root,
             git_dir,
             ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
             limits
           ) do
      paths = output |> String.split(<<0>>, trim: true) |> Enum.uniq()

      if length(paths) > limits.max_files do
        {:error, :source_too_large}
      else
        Alto.Result.reduce(paths, 0, fn relative, bytes ->
          path = Path.expand(relative, root)

          with :ok <- reject_symlink_components(path) do
            case File.lstat(path) do
              {:ok, %{type: :regular, size: size}}
              when bytes + size <= limits.max_checkout_bytes ->
                {:ok, bytes + size}

              {:error, :enoent} ->
                {:ok, bytes}

              {:ok, %{type: :directory}} ->
                {:error, :submodule_unsupported}

              {:ok, _} ->
                {:error, :source_too_large}

              {:error, reason} ->
                {:error, reason}
            end
          end
        end)
        |> case do
          {:ok, _} -> :ok
          error -> error
        end
      end
    end
  end

  defp bounded_tree(path, max_bytes, max_files) do
    with {:ok, _counts} <- walk(path, {0, 0}, max_bytes, max_files), do: :ok
  end

  defp walk(path, {bytes, files}, max_bytes, max_files) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_unsupported}

      {:ok, %File.Stat{type: :regular, size: size}}
      when bytes + size <= max_bytes and files + 1 <= max_files ->
        {:ok, {bytes + size, files + 1}}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :source_too_large}

      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, entries} <- File.ls(path) do
          Alto.Result.reduce(entries, {bytes, files}, fn entry, counts ->
            walk(Path.join(path, entry), counts, max_bytes, max_files)
          end)
        else
          {:error, reason} -> {:error, {:source_read_failed, reason}}
        end

      {:ok, _} ->
        {:error, :unsupported_source_entry}

      {:error, reason} ->
        {:error, {:source_stat_failed, reason}}
    end
  end

  defp reject_new_path(path) do
    expanded = Path.expand(path)

    if File.exists?(expanded),
      do: {:error, :destination_exists},
      else: reject_symlink_components(Path.dirname(expanded))
  end

  defp repository_layout(root, %{layout: :clone}), do: ordinary_repository(root)

  defp repository_layout(root, limits) do
    with {:ok, _} <- common_dir(root, limits), do: :ok
  end

  defp source_metadata(root, %{layout: :clone}), do: {:ok, Path.join(root, ".git")}
  defp source_metadata(root, limits), do: common_dir(root, limits)

  defp common_dir(root, limits) do
    with :ok <- reject_symlink_components(Path.join(root, ".git")),
         {:ok, output} <-
           git(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"], limits),
         path <- String.trim(output),
         :ok <- reject_symlink_components(path),
         true <- File.dir?(path) or {:error, :invalid_git_pointer} do
      {:ok, path}
    end
  end

  defp validate_branch(_root, nil, _limits), do: :ok

  defp validate_branch(root, branch, limits) do
    with {:ok, _} <- Alto.Tools.Git.ref(branch),
         {:ok, _} <- git(root, ["check-ref-format", "refs/heads/" <> branch], limits),
         do: :ok
  end

  defp linked_source(snapshot, limits) do
    with {:ok, root} <- repository_root(snapshot["source"], limits),
         {:ok, common} <- common_dir(root, limits),
         true <- common == snapshot["common_dir"] or {:error, :wrong_workspace},
         :ok <- bounded_source(root, limits),
         :ok <- reject_source_filters(root, limits),
         :ok <- validate_branch(root, snapshot["branch"], limits),
         {:ok, _} <-
           checkout_size(root, snapshot["base_commit"], limits.max_checkout_bytes, limits) do
      :ok
    end
  end

  defp checkout_linked(snapshot, root, limits) do
    branch_args = if snapshot["branch"], do: ["-b", snapshot["branch"]], else: ["--detach"]

    with :ok <- linked_source(snapshot, limits),
         :ok <- reject_new_path(root),
         :ok <- File.mkdir_p(Path.dirname(root)),
         {:ok, _} <-
           git(
             snapshot["source"],
             ["worktree", "add"] ++ branch_args ++ ["--", root, snapshot["base_commit"]],
             limits
           ),
         {:ok, git_dir} <- workspace_metadata(root, snapshot, limits),
         :ok <- verify_checkout(root, snapshot, limits, git_dir) do
      :ok
    end
  end

  defp workspace_metadata(root, _snapshot, %{layout: :clone}) do
    git_dir = root <> ".git"
    with :ok <- verify_git_pointer(root, git_dir), do: {:ok, git_dir}
  end

  defp workspace_metadata(root, snapshot, limits) do
    # Check both sides of Git's linkage before staging or removing anything.
    with :ok <- reject_symlink_components(root),
         {:ok, common} <- common_dir(root, limits),
         true <- common == snapshot["common_dir"] or {:error, :invalid_git_pointer},
         {:ok, output} <- git(root, ["rev-parse", "--absolute-git-dir"], limits),
         git_dir <- String.trim(output),
         true <-
           Path.dirname(git_dir) == Path.join(common, "worktrees") or
             {:error, :invalid_git_pointer},
         :ok <- verify_git_pointer(root, git_dir),
         {:ok, backref} <- File.read(Path.join(git_dir, "gitdir")),
         true <- String.trim(backref) == Path.join(root, ".git") or {:error, :invalid_git_pointer} do
      {:ok, git_dir}
    end
  end

  @doc false
  def discard(snapshot, destination, opts) do
    with {:ok, limits} <- limits(opts) do
      if Map.has_key?(snapshot, "common_dir"),
        do: discard_linked(snapshot, destination, %{limits | layout: :worktree}),
        else: :ok
    end
  end

  defp discard_linked(snapshot, destination, limits) do
    with {:ok, snapshot} <- validate_snapshot(snapshot),
         root <- Path.expand(destination),
         {:ok, common} <- common_dir(snapshot["source"], limits),
         true <- common == snapshot["common_dir"] or {:error, :wrong_workspace} do
      with :ok <- reject_symlink_components(root),
           {:ok, registered} <-
             git(snapshot["source"], ["worktree", "list", "--porcelain", "-z"], limits) do
        if ("worktree " <> root) in String.split(registered, <<0>>) do
          # A missing checkout is recoverable after an interrupted removal.
          with :ok <- verify_removal(root, snapshot, limits),
               {:ok, _} <-
                 git(snapshot["source"], ["worktree", "remove", "--force", "--", root], limits),
               do: :ok
        else
          # No registration was made, or Git already rolled back a failed add.
          :ok
        end
      end
    end
  end

  defp verify_removal(root, snapshot, limits) do
    if File.exists?(root) do
      with {:ok, _} <- workspace_metadata(root, snapshot, limits), do: :ok
    else
      :ok
    end
  end

  defp reject_symlink_components(path) do
    case Alto.Workspaces.safe_path(path) do
      {:error, :workspace_path_symlink} -> {:error, :symlink_unsupported}
      {:error, reason} -> {:error, {:path_stat_failed, reason}}
      :ok -> :ok
    end
  end

  defp git(cwd, args, limits, extra \\ []) do
    case {System.find_executable("git"), System.find_executable("env")} do
      {nil, _} ->
        {:error, :git_not_found}

      {_, nil} ->
        {:error, :env_not_found}

      {executable, env} ->
        path = System.get_env("PATH") || "/usr/local/bin:/usr/bin:/bin"

        command = %{
          "program" => env,
          "args" => [
            "-i",
            "HOME=/tmp",
            "PATH=" <> path,
            "GIT_CONFIG_NOSYSTEM=1",
            "GIT_CONFIG_GLOBAL=/dev/null",
            "GIT_TERMINAL_PROMPT=0",
            executable | git_args(args)
          ],
          "timeout_ms" => limits.timeout_ms,
          "max_output_bytes" => Keyword.get(extra, :max_output_bytes, 64_000)
        }

        case Command.run(command, %{session_id: "alto-workspace-git", cwd: cwd}) do
          {:ok, %{termination: :timeout}} -> {:error, :git_timeout}
          {:ok, %{termination: :output_limit}} -> {:error, :git_output_limit}
          {:ok, %{truncated: true}} -> {:error, :git_output_limit}
          {:ok, %{exit_status: 0, output: output}} -> {:ok, output}
          {:ok, %{exit_status: status, output: output}} -> {:error, {:git_failed, status, output}}
          {:ok, other} -> {:error, {:git_uncertain, other}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp workspace_git(cwd, git_dir, args, limits, extra \\ []) do
    git(cwd, ["--git-dir", git_dir, "--work-tree", cwd | args], limits, extra)
  end

  defp git_args(args),
    do: [
      "--no-pager",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "core.sshCommand=",
      "-c",
      "core.fsmonitor=false",
      "-c",
      "gc.auto=0",
      "-c",
      "maintenance.auto=false",
      "-c",
      "color.ui=false" | args
    ]

  defp valid_hex?(value, size),
    do: byte_size(value) == size and Regex.match?(~r/\A[0-9a-f]+\z/, value)
end
