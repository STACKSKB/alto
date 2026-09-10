defmodule Alto.DurableLog do
  @moduledoc false

  import Bitwise

  @doc false
  def ensure(path) do
    if File.exists?(path), do: :ok, else: append(path, "")
  end

  @doc false
  def append(path, iodata) do
    existed? = File.exists?(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:append, :binary, :raw]),
         result <- write_sync_close(io, iodata),
         :ok <- result,
         :ok <- maybe_sync_parent(path, existed?) do
      :ok
    end
  end

  @doc false
  def replace(path, iodata, opts \\ []) do
    dir = Path.dirname(path)
    temp = path <> ".repair-" <> random_suffix()
    before_rename = Keyword.get(opts, :before_rename, fn -> :ok end)
    mode = existing_mode(path)

    result =
      with :ok <- File.mkdir_p(dir),
           {:ok, io} <- File.open(temp, [:write, :binary, :raw, :exclusive]),
           :ok <- maybe_chmod(temp, mode),
           write_result <- write_sync_close(io, iodata),
           :ok <- write_result,
           :ok <- before_rename.(),
           :ok <- File.rename(temp, path),
           :ok <- sync_directory(dir) do
        :ok
      end

    if result != :ok, do: File.rm(temp)
    result
  end

  defp write_sync_close(io, iodata) do
    result =
      with :ok <- :file.write(io, iodata),
           :ok <- :file.sync(io) do
        :ok
      end

    case File.close(io) do
      :ok -> result
      {:error, reason} when result == :ok -> {:error, reason}
      _close_error -> result
    end
  end

  defp maybe_sync_parent(_path, true), do: :ok
  defp maybe_sync_parent(path, false), do: sync_directory(Path.dirname(path))

  @doc false
  def sync_directory(dir) do
    case System.cmd("sync", ["-d", dir], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:directory_sync_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:directory_sync_failed, Exception.message(error)}}
  end

  defp random_suffix do
    Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end

  defp existing_mode(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> mode &&& 0o7777
      {:error, _reason} -> nil
    end
  end

  defp maybe_chmod(_path, nil), do: :ok
  defp maybe_chmod(path, mode), do: File.chmod(path, mode)
end
