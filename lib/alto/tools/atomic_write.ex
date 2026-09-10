defmodule Alto.Tools.AtomicWrite do
  @moduledoc false

  import Bitwise

  @doc """
  Write `content` to `path` by writing a uniquely-named sibling temp file and
  renaming it into place, so a crash or kill mid-write leaves the target either
  fully old or fully new, never partial.

  When `mode` is given, the temp file is chmod'ed to it before the rename. When
  it is omitted, an existing target's mode is preserved; a new target uses the
  default umask permissions.
  """
  @spec write(binary(), binary(), non_neg_integer() | nil) :: :ok | {:error, term()}
  def write(path, content, mode \\ nil) do
    with {:ok, mode} <- effective_mode(path, mode) do
      write_temp(path, content, mode)
    end
  end

  defp write_temp(path, content, mode) do
    temp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.alto-#{random_suffix()}.tmp"
      )

    result =
      case File.open(temp, [:write, :binary, :exclusive]) do
        {:ok, io} ->
          result =
            with :ok <- maybe_chmod(temp, mode),
                 :ok <- :file.write(io, content),
                 :ok <- :file.sync(io),
                 :ok <- File.close(io),
                 :ok <- File.rename(temp, path) do
              :ok
            end

          if result != :ok, do: File.close(io)
          result

        {:error, reason} ->
          {:error, reason}
      end

    if result != :ok, do: File.rm(temp)
    result
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
