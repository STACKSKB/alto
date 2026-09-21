defmodule Alto.DurableLog do
  @moduledoc false

  @doc "Open a private durable log before replay, under the caller's storage lock."
  def open(dir, path) do
    with :ok <- Alto.Storage.ensure_private_dir(dir, owned: true),
         :ok <- Alto.Storage.ensure_private_file(path),
         do: ensure(path)
  end

  @doc "Replay validated lines and repair a torn tail only after the domain decoder succeeds."
  def replay(path, max_bytes, decode) do
    case Alto.BoundedFile.read(path, max_bytes) do
      {:ok, contents} ->
        {lines, torn?} = Alto.JSONLines.split(contents)

        with {:ok, value} <- decode.(lines) do
          case if(torn?, do: replace(path, Alto.JSONLines.join(lines)), else: :ok) do
            :ok -> {:ok, value}
            {:error, reason} -> {:read_error, reason}
          end
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:read_error, reason}
    end
  end

  @doc false
  def ensure(path) do
    if File.exists?(path), do: :ok, else: append(path, "")
  end

  @doc false
  def append(path, iodata) do
    existed? = File.exists?(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:append, :binary, :raw]),
         result <- Alto.AtomicFile.write_sync_close(io, iodata),
         :ok <- result,
         :ok <- maybe_sync_parent(path, existed?) do
      :ok
    end
  end

  @doc false
  def replace(path, iodata, opts \\ []) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         do: Alto.AtomicFile.write(path, iodata, opts)
  end

  defp maybe_sync_parent(_path, true), do: :ok
  defp maybe_sync_parent(path, false), do: Alto.AtomicFile.sync_directory(Path.dirname(path))
end
