defmodule Alto.AtomicFile do
  @moduledoc false

  import Bitwise

  @doc """
  Write `content` to `path` by writing a uniquely-named sibling temp file and
  renaming it into place, so a crash or kill mid-write leaves the target either
  fully old or fully new, never partial.

  When `:mode` is given, the temp file is chmod'ed to it before the rename. When
  it is omitted, an existing target's mode is preserved; a new target uses the
  default umask permissions.

  The parent directory is synced after rename. If that sync fails, the rename
  may already have succeeded and the returned `{:error, {:post_rename_sync_failed, reason}}`
  is therefore an uncertain outcome for callers.
  """
  @spec write(binary(), iodata(), keyword()) :: :ok | {:error, term()}
  def write(path, content, opts \\ []) do
    with {:ok, mode} <- effective_mode(path, Keyword.get(opts, :mode)) do
      write_temp(path, content, mode, opts, true)
    end
  end

  @doc """
  Publish independent files and sync each containing directory once after every
  file's bytes have been synced and renamed. This is not a multi-file transaction:
  an error may leave a published prefix. Callers must publish any manifest/head
  only after success. This is suitable for immutable content-addressed objects.
  """
  def write_many(files) do
    with {:ok, _} <-
           Alto.Result.reduce(files, :ok, fn {path, content, opts}, :ok ->
             with {:ok, mode} <- effective_mode(path, Keyword.get(opts, :mode)),
                  :ok <- write_temp(path, content, mode, opts, false),
                  do: {:ok, :ok}
           end),
         {:ok, _} <-
           files
           |> Enum.map(fn {path, _, _} -> Path.dirname(path) end)
           |> Enum.uniq()
           |> Alto.Result.traverse(fn dir ->
             case sync_directory(dir) do
               :ok -> {:ok, :ok}
               {:error, reason} -> {:error, {:post_rename_sync_failed, reason}}
             end
           end),
         do: :ok
  end

  defp write_temp(path, content, mode, opts, sync_directory?) do
    temp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.alto-#{random_suffix()}.tmp"
      )

    before_rename = Keyword.get(opts, :before_rename, fn -> :ok end)

    result =
      with {:ok, io} <- File.open(temp, [:write, :binary, :raw, :exclusive]),
           :ok <- write_sync_close(io, content, fn -> maybe_chmod(temp, mode) end),
           :ok <- before_rename.(),
           :ok <- File.rename(temp, path) do
        case if(sync_directory?, do: sync_directory(Path.dirname(path)), else: :ok) do
          :ok -> :ok
          {:error, reason} -> {:error, {:post_rename_sync_failed, reason}}
        end
      end

    if result != :ok, do: File.rm(temp)
    result
  end

  @doc false
  def write_sync_close(io, content, before_write \\ fn -> :ok end) do
    result =
      try do
        with :ok <- before_write.(),
             :ok <- :file.write(io, content),
             do: :file.sync(io)
      catch
        kind, reason ->
          File.close(io)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    close_result = File.close(io)
    if result == :ok, do: close_result, else: result
  end

  @doc false
  def sync_directory(dir) do
    case System.cmd("sync", ["-d", dir], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:directory_sync_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:directory_sync_failed, Exception.message(error)}}
  end

  defp effective_mode(_path, mode) when is_integer(mode) and mode >= 0, do: {:ok, mode}

  defp effective_mode(path, nil) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat.mode}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_chmod(_temp, nil), do: :ok
  defp maybe_chmod(temp, mode), do: File.chmod(temp, mode &&& 0o7777)

  defp random_suffix do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
