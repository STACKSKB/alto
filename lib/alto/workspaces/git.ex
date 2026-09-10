defmodule Alto.Workspaces.Git do
  @moduledoc "Bounded independent local Git clones for isolated child workspaces."

  @behaviour Alto.Workspaces.Backend

  alias Alto.Command
  alias Alto.Tool.Context

  @default_source_bytes 512 * 1_024 * 1_024
  @default_max_files 20_000
  @default_checkout_bytes 128 * 1_024 * 1_024
  @default_patch_bytes 1_000_000
  @default_timeout 120_000

  @doc false
  def command(cwd, args, opts \\ []) do
    with {:ok, limits} <- limits(opts), do: git(cwd, args, limits)
  end

  @doc false
  def integration_target(repo, opts \\ []) do
    with {:ok, limits} <- limits(opts),
         {:ok, root} <- repository_root(repo, limits),
         :ok <- bounded_tree(Path.join(root, ".git"), limits.max_source_bytes, limits.max_files),
         :ok <- reject_alternates(root),
         :ok <- reject_source_filters(root, limits),
         {:ok, head} <- git(root, ["rev-parse", "--verify", "HEAD^{commit}"], limits),
         {:ok, config} <- git(root, ["config", "--includes", "--null", "--list"], limits),
         {:ok, stat} <- File.stat(root) do
      {:ok,
       %{
         "root" => root,
         "head" => String.trim(head),
         "inode" => stat.inode,
         "device" => stat.major_device,
         "config_sha256" => Base.encode16(:crypto.hash(:sha256, config), case: :lower)
       }}
    end
  end

  @spec snapshot(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(repo, opts \\ []) when is_binary(repo) and is_list(opts) do
    with {:ok, limits} <- limits(opts),
         {:ok, root} <- repository_root(repo, limits),
         :ok <- bounded_tree(Path.join(root, ".git"), limits.max_source_bytes, limits.max_files),
         :ok <- reject_alternates(root),
         :ok <- reject_source_filters(root, limits),
         {:ok, commit} <- git(root, ["rev-parse", "--verify", "HEAD^{commit}"], limits),
         {:ok, tree} <- git(root, ["rev-parse", "--verify", "HEAD^{tree}"], limits),
         {:ok, _} <- checkout_size(root, String.trim(commit), limits.max_checkout_bytes, limits),
         {:ok, status} <-
           git(
             root,
             ["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=all"],
             limits
           ),
         true <- String.trim(status) == "" or {:error, :source_dirty} do
      {:ok,
       %{"source" => root, "base_commit" => String.trim(commit), "base_tree" => String.trim(tree)}}
    else
      false -> {:error, :source_dirty}
      {:error, _} = error -> error
    end
  end

  @spec checkout(map(), Path.t(), keyword()) :: :ok | {:error, term()}
  def checkout(snapshot, destination, opts \\ [])
      when is_map(snapshot) and is_binary(destination) do
    with {:ok, limits} <- limits(opts),
         {:ok, snapshot} <- validate_snapshot(snapshot),
         :ok <- ordinary_repository(snapshot["source"]),
         :ok <-
           bounded_tree(
             Path.join(snapshot["source"], ".git"),
             limits.max_source_bytes,
             limits.max_files
           ),
         :ok <- reject_alternates(snapshot["source"]),
         {:ok, _} <-
           checkout_size(
             snapshot["source"],
             snapshot["base_commit"],
             limits.max_checkout_bytes,
             limits
           ),
         :ok <- reject_new_path(destination),
         :ok <- reject_new_path(Path.expand(destination) <> ".git"),
         :ok <- File.mkdir_p(Path.dirname(Path.expand(destination))),
         git_dir <- Path.expand(destination) <> ".git",
         {:ok, _} <-
           git(
             Path.dirname(Path.expand(destination)),
             [
               "clone",
               "--local",
               "--no-hardlinks",
               "--no-checkout",
               "--separate-git-dir",
               git_dir,
               "--template=/dev/null",
               snapshot["source"],
               Path.expand(destination)
             ],
             limits
           ),
         :ok <- verify_git_pointer(Path.expand(destination), git_dir),
         {:ok, _} <-
           workspace_git(
             Path.expand(destination),
             git_dir,
             ["checkout", "--detach", snapshot["base_commit"]],
             limits
           ),
         :ok <- verify_checkout(Path.expand(destination), snapshot, limits, git_dir) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  @spec diff(map(), Path.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def diff(snapshot, destination, opts \\ []) when is_map(snapshot) and is_binary(destination) do
    with {:ok, limits} <- limits(opts),
         {:ok, snapshot} <- validate_snapshot(snapshot),
         root <- Path.expand(destination),
         git_dir <- root <> ".git",
         :ok <- verify_git_pointer(root, git_dir),
         true <- File.dir?(root) or {:error, :wrong_workspace},
         :ok <- verify_checkout(root, snapshot, limits, git_dir),
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
    else
      false -> {:error, :wrong_workspace}
      {:error, _} = error -> error
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
    defaults = [
      max_source_bytes: @default_source_bytes,
      max_files: @default_max_files,
      max_checkout_bytes: @default_checkout_bytes,
      max_patch_bytes: @default_patch_bytes,
      timeout_ms: @default_timeout
    ]

    if Keyword.keyword?(opts) and Keyword.keys(opts) -- Keyword.keys(defaults) == [] do
      values = Keyword.merge(defaults, opts)

      with :ok <- positive(values[:max_source_bytes], :max_source_bytes),
           :ok <- positive(values[:max_files], :max_files),
           :ok <- positive(values[:max_checkout_bytes], :max_checkout_bytes),
           :ok <- positive(values[:max_patch_bytes], :max_patch_bytes),
           :ok <- positive(values[:timeout_ms], :timeout_ms),
           true <- values[:timeout_ms] <= @default_timeout or {:error, :invalid_timeout},
           true <-
             values[:max_patch_bytes] <= @default_patch_bytes or {:error, :invalid_patch_limit} do
        {:ok, Map.new(values)}
      else
        false -> {:error, :invalid_workspace_limits}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_workspace_options}
    end
  end

  defp positive(value, _name) when is_integer(value) and value > 0, do: :ok
  defp positive(_, name), do: {:error, {:invalid_workspace_limit, name}}

  defp repository_root(repo, limits) do
    root = Path.expand(repo)

    with true <- File.dir?(root) or {:error, :repository_not_found},
         :ok <- reject_symlink_components(root),
         :ok <- ordinary_repository(root),
         {:ok, reported} <- git(root, ["rev-parse", "--show-toplevel"], limits),
         true <- Path.expand(String.trim(reported)) == root or {:error, :not_repository} do
      {:ok, root}
    else
      false -> {:error, :repository_not_found}
      {:error, _} = error -> error
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
       when map_size(snapshot) == 3 and is_binary(source) and is_binary(commit) and
              is_binary(tree) do
    with true <- Path.expand(source) == source or {:error, :invalid_snapshot},
         true <- (valid_hex?(commit, 40) and valid_hex?(tree, 40)) or {:error, :invalid_snapshot},
         :ok <- reject_symlink_components(source),
         true <- File.dir?(source) or {:error, :invalid_snapshot} do
      {:ok, snapshot}
    else
      false -> {:error, :invalid_snapshot}
      {:error, _} = error -> error
    end
  end

  defp validate_snapshot(_), do: {:error, :invalid_snapshot}

  defp verify_checkout(root, snapshot, limits, git_dir) do
    runner = &workspace_git(root, git_dir, &1, limits)

    with {:ok, head} <- runner.(["rev-parse", "--verify", "HEAD^{commit}"]),
         {:ok, tree} <- runner.(["rev-parse", "--verify", "HEAD^{tree}"]),
         true <- String.trim(head) == snapshot["base_commit"] or {:error, :stale_workspace},
         true <- String.trim(tree) == snapshot["base_tree"] or {:error, :stale_workspace} do
      :ok
    else
      false -> {:error, :stale_workspace}
      {:error, _} = error -> error
    end
  end

  defp reject_index_gitlinks(root, git_dir, limits) do
    case workspace_git(root, git_dir, ["ls-files", "--stage", "-z"], limits) do
      {:ok, output} ->
        if output
           |> String.split(<<0>>, trim: true)
           |> Enum.any?(fn entry -> String.starts_with?(entry, "160000 ") end) do
          {:error, :submodule_unsupported}
        else
          :ok
        end

      error ->
        error
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
      false -> {:error, :invalid_git_pointer}
      {:ok, _} -> {:error, :invalid_git_pointer}
      {:error, _} = error -> error
    end
  end

  defp checkout_size(root, commit, max, limits) do
    with {:ok, output} <- git(root, ["ls-tree", "-r", "-l", "--full-tree", commit], limits),
         {:ok, total} <- parse_tree_sizes(output, max, limits.max_files),
         do: {:ok, total}
  end

  defp parse_tree_sizes(output, max, max_files) do
    lines = String.split(output, "\n", trim: true)

    if length(lines) > max_files do
      {:error, :checkout_too_large}
    else
      Enum.reduce_while(lines, {:ok, 0}, fn line, {:ok, total} ->
        case String.split(line, "\t", parts: 2) do
          [mode_type_size, _path] ->
            case String.split(mode_type_size, " ", trim: true) do
              ["120000", "blob", _hash, _size] ->
                {:halt, {:error, :symlink_unsupported}}

              [mode, "blob", _hash, size] when mode in ["100644", "100755"] ->
                case Integer.parse(size) do
                  {bytes, ""} when total + bytes <= max -> {:cont, {:ok, total + bytes}}
                  {_, ""} -> {:halt, {:error, :checkout_too_large}}
                  _ -> {:halt, {:error, :invalid_tree}}
                end

              [_mode, "commit", _hash, _size] ->
                {:halt, {:error, :submodule_unsupported}}

              _ ->
                {:halt, {:error, :invalid_tree}}
            end

          _ ->
            {:halt, {:error, :invalid_tree}}
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
        Enum.reduce_while(paths, {:ok, 0}, fn relative, {:ok, bytes} ->
          path = Path.expand(relative, root)

          result =
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

          case result do
            {:ok, next} -> {:cont, {:ok, next}}
            error -> {:halt, error}
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
    case walk(path, 0, 0, max_bytes, max_files) do
      {:ok, _, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp walk(path, bytes, files, max_bytes, max_files) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_unsupported}

      {:ok, %File.Stat{type: :regular, size: size}}
      when bytes + size <= max_bytes and files + 1 <= max_files ->
        {:ok, bytes + size, files + 1}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :source_too_large}

      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, entries} <- File.ls(path) do
          Enum.reduce_while(entries, {:ok, bytes, files}, fn entry, {:ok, b, f} ->
            case walk(Path.join(path, entry), b, f, max_bytes, max_files) do
              {:ok, b, f} -> {:cont, {:ok, b, f}}
              {:error, _} = error -> {:halt, error}
            end
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

  defp reject_alternates(root) do
    if File.exists?(Path.join(root, ".git/objects/info/alternates")),
      do: {:error, :alternates_unsupported},
      else: :ok
  end

  defp reject_symlink_components(path) do
    expanded = Path.expand(path)

    {root, parts} =
      if String.starts_with?(expanded, "/"),
        do: {"/", Path.split(expanded) |> tl()},
        else: {"", Path.split(expanded)}

    parts
    |> Enum.reduce_while({:ok, root}, fn part, {:ok, prefix} ->
      current = if prefix == "/", do: "/" <> part, else: Path.join(prefix, part)

      case File.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink_unsupported}}
        {:ok, _} -> {:cont, {:ok, current}}
        {:error, :enoent} -> {:cont, {:ok, current}}
        {:error, reason} -> {:halt, {:error, {:path_stat_failed, reason}}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
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

        case Command.run(command, %Context{session_id: "alto-workspace-git", cwd: cwd}) do
          {:ok, %{termination: :timeout}} -> {:error, :git_timeout}
          {:ok, %{termination: :output_limit}} -> {:error, :git_output_limit}
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
