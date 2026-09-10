defmodule Alto.Workspaces.GitPatch do
  @moduledoc false
  alias Alto.Workspaces.Git
  alias Alto.Workspaces
  alias Alto.DurableLog

  @max_manifest_bytes 32_000
  @max_files 256
  @max_file_bytes 128 * 1_024 * 1_024

  # Git parses its own patch grammar. Forward/reverse numstat together include
  # both sides of renames, including names containing tabs and newlines.
  def prepare(target, patch_path, patch_sha256, opts \\ []) do
    with :ok <- verify_patch(patch_path, patch_sha256),
         {:ok, repo} <- Git.integration_target(target, opts),
         {:ok, forward} <-
           Git.command(target, ["apply", "--numstat", "-z", "--", patch_path], opts),
         {:ok, reverse} <-
           Git.command(target, ["apply", "--reverse", "--numstat", "-z", "--", patch_path], opts),
         {:ok, paths} <- paths(forward <> reverse),
         {:ok, files} <- snapshots(target, paths),
         {:ok, _} <-
           Git.command(
             target,
             ["apply", "--check", "--whitespace=nowarn", "--", patch_path],
             opts
           ) do
      prepared = %{
        "version" => 1,
        "engine" => engine(),
        "target" => repo,
        "patch_sha256" => patch_sha256,
        "files" => files
      }

      with :ok <- manifest_bound(prepared),
           :ok <- verify(prepared, patch_path, opts),
           do: {:ok, prepared}
    end
  end

  def verify(
        %{"version" => 1, "engine" => version, "target" => repo, "files" => files} = prepared,
        patch_path,
        opts
      )
      when is_map(repo) and is_list(files) do
    with :ok <- manifest_bound(prepared),
         :ok <- verify_patch(patch_path, prepared["patch_sha256"]),
         true <- version == engine(),
         true <- length(files) in 1..@max_files,
         true <- Enum.all?(files, &(is_map(&1) and is_binary(&1["path"]))),
         target when is_binary(target) <- repo["root"],
         {:ok, current_repo} <- Git.integration_target(target, opts),
         true <- current_repo == repo,
         {:ok, current} <- snapshots(target, Enum.map(files, & &1["path"])),
         true <- current == files,
         {:ok, _} <-
           Git.command(
             target,
             ["apply", "--check", "--whitespace=nowarn", "--", patch_path],
             opts
           ) do
      :ok
    else
      false -> {:error, :stale_patch_target}
      {:error, _} = error -> error
      _ -> {:error, :invalid_prepared_patch}
    end
  end

  def verify(_, _, _), do: {:error, :invalid_prepared_patch}

  # Caller has fenced the resource and verified all preconditions under its
  # target lock. Once Git starts, every failure is uncertain: multi-file writes
  # can partially complete even if Git subsequently returns a nonzero status.
  def apply(prepared, patch_path, opts) do
    target = prepared["target"]["root"]
    paths = Enum.map(prepared["files"], & &1["path"])

    with {:ok, _} <-
           Git.command(target, ["apply", "--whitespace=nowarn", "--", patch_path], opts),
         :ok <- sync_paths(target, paths),
         {:ok, after_files} <- snapshots(target, paths) do
      {:ok,
       %{
         "target" => target,
         "patch_sha256" => prepared["patch_sha256"],
         "files" => Enum.map(after_files, & &1["path"])
       }}
    else
      {:error, reason} -> {:unknown, {:patch_application_uncertain, reason}}
    end
  end

  defp paths(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, paths} ->
      case String.split(record, "\t", parts: 3) do
        [_added, _removed, path] ->
          case valid_path(path) do
            :ok -> {:cont, {:ok, [path | paths]}}
            error -> {:halt, error}
          end

        _ ->
          {:halt, {:error, :invalid_patch_stat}}
      end
    end)
    |> case do
      {:ok, paths} ->
        paths = paths |> Enum.uniq() |> Enum.sort()

        if length(paths) in 1..@max_files,
          do: {:ok, paths},
          else: {:error, :patch_file_count_exceeded}

      error ->
        error
    end
  end

  defp valid_path(path) when is_binary(path) do
    parts = String.split(path, "/")

    if String.valid?(path) and byte_size(path) in 1..4_096 and Path.type(path) == :relative and
         Enum.all?(parts, &(&1 not in ["", ".", "..", ".git"])) and
         not String.contains?(path, <<0>>),
       do: :ok,
       else: {:error, :invalid_patch_path}
  end

  defp valid_path(_), do: {:error, :invalid_patch_path}

  defp snapshots(root, paths) do
    Enum.reduce_while(paths, {:ok, [], 0}, fn path, {:ok, files, bytes} ->
      with :ok <- valid_path(path),
           full <- Path.join(root, path),
           :ok <- Workspaces.safe_path(full),
           {:ok, state} <- snapshot(full, @max_file_bytes - bytes) do
        {:cont,
         {:ok, [%{"path" => path, "original" => state} | files],
          bytes + Map.get(state, "bytes", 0)}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files, _} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp snapshot(path, remaining) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, %{"type" => "absent"}}

      {:ok, %{type: :regular, size: size} = stat} when size <= remaining ->
        with {:ok, digest} <- file_digest(path, remaining),
             {:ok, after_stat} <- File.lstat(path),
             true <-
               Map.drop(Map.from_struct(stat), [:atime]) ==
                 Map.drop(Map.from_struct(after_stat), [:atime]) do
          {:ok,
           %{
             "type" => "file",
             "bytes" => size,
             "mode" => stat.mode,
             "inode" => stat.inode,
             "device" => stat.major_device,
             "sha256" => digest
           }}
        else
          false -> {:error, :patch_target_changed_during_read}
          error -> error
        end

      {:ok, %{type: :regular}} ->
        {:error, :patch_target_too_large}

      {:ok, _} ->
        {:error, :unsupported_patch_target}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_patch(path, expected) do
    with :ok <- Workspaces.safe_path(path),
         {:ok, %{type: :regular, size: size}} when size <= 1_000_000 <- File.lstat(path),
         {:ok, digest} <- file_digest(path, 1_000_000),
         true <- digest == expected do
      :ok
    else
      _ -> {:error, :workspace_patch_changed}
    end
  end

  defp file_digest(path, remaining) do
    with {:ok, io} <- File.open(path, [:read, :raw, :binary]) do
      try do
        digest_chunks(io, :crypto.hash_init(:sha256), remaining)
      after
        File.close(io)
      end
    end
  end

  defp digest_chunks(io, state, remaining) do
    case IO.binread(io, min(remaining + 1, 64_000)) do
      :eof ->
        {:ok, Base.encode16(:crypto.hash_final(state), case: :lower)}

      bytes when is_binary(bytes) and byte_size(bytes) <= remaining ->
        digest_chunks(io, :crypto.hash_update(state, bytes), remaining - byte_size(bytes))

      bytes when is_binary(bytes) ->
        {:error, :patch_target_too_large}

      error ->
        error
    end
  end

  defp sync_paths(root, paths) do
    Enum.reduce_while(paths, :ok, fn relative, :ok ->
      path = Path.join(root, relative)

      with :ok <- Workspaces.safe_path(path),
           :ok <- sync_file(path),
           :ok <- sync_parents(Path.dirname(path), root) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp sync_file(path) do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          :file.sync(io)
        after
          File.close(io)
        end

      {:error, :enoent} ->
        :ok

      error ->
        error
    end
  end

  defp sync_parents(dir, root) do
    with :ok <- if(File.dir?(dir), do: DurableLog.sync_directory(dir), else: :ok) do
      if dir == root, do: :ok, else: sync_parents(Path.dirname(dir), root)
    end
  end

  defp manifest_bound(prepared) do
    if byte_size(JSON.encode!(prepared)) <= @max_manifest_bytes,
      do: :ok,
      else: {:error, :patch_manifest_too_large}
  rescue
    _ -> {:error, :invalid_prepared_patch}
  end

  defp engine do
    :crypto.hash(:sha256, __MODULE__.module_info(:md5) <> Git.module_info(:md5))
    |> Base.encode16(case: :lower)
  end
end
