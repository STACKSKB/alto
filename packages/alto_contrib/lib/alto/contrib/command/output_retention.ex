defmodule Alto.Contrib.Command.OutputRetention do
  @moduledoc false
  alias Alto.Contrib.Tools.Path, as: SafePath

  @schema [
    directory: [type: :string, default: ".alto/command-output"],
    max_bytes: [type: {:in, 1..1_000_000_000}, default: 8_000_000],
    max_files: [type: {:in, 1..1024}, default: 16]
  ]

  # Preparation freezes host policy but creates no files before approval.
  def prepare(invocation, opts) do
    case Keyword.get(opts, :output_retention, false) do
      false -> {:ok, invocation, %{}}
      config when is_list(config) -> prepare_config(invocation, config)
      _ -> {:error, :invalid_output_retention}
    end
  end

  defp prepare_config(invocation, config) do
    with {:ok, config} <- NimbleOptions.validate(config, @schema),
         {:ok, directory} <- SafePath.resolve(config[:directory], invocation.cwd) do
      policy =
        config
        |> Map.new()
        |> Map.merge(%{
          requested_directory: config[:directory],
          directory: directory,
          root: Path.expand(invocation.cwd)
        })

      {:ok, Map.put(invocation, :output_retention, policy),
       %{output_retention: Map.take(policy, [:directory, :max_bytes, :max_files])}}
    else
      {:error, %NimbleOptions.ValidationError{}} -> {:error, :invalid_output_retention}
      {:error, _} = error -> error
    end
  end

  def open(nil), do: nil

  def open(policy) do
    with {:ok, directory} <-
           SafePath.revalidate(policy.requested_directory, policy.directory, policy.root),
         :ok <- File.mkdir_p(directory),
         {:ok, ^directory} <- SafePath.resolve(directory, policy.root) do
      reserve(policy, 1)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :retention_directory_changed}
    end
  end

  # mkdir is the atomic quota reservation. Existing entries (including symlinks)
  # are never reused, and every reservation holds at most one bounded file.
  defp reserve(%{max_files: max}, slot) when slot > max,
    do: {:error, :output_retention_full}

  defp reserve(policy, slot) do
    directory = Path.join(policy.directory, "slot-#{slot}")

    case File.mkdir(directory) do
      :ok -> open_reserved(policy, directory)
      {:error, :eexist} -> reserve(policy, slot + 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_reserved(policy, directory) do
    path = Path.join(directory, Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false))

    with {:ok, ^path} <- SafePath.resolve(path, policy.root),
         :ok <- File.chmod(directory, 0o700),
         {:ok, file} <- File.open(path, [:write, :exclusive, :raw, :binary]) do
      %{
        file: file,
        path: path,
        directory: directory,
        root: policy.root,
        max_bytes: policy.max_bytes,
        bytes: 0,
        error: nil
      }
    else
      error ->
        File.rmdir(directory)

        case error do
          {:error, reason} -> {:error, reason}
          _ -> {:error, :retention_directory_changed}
        end
    end
  end

  def append(%{error: nil} = capture, data) do
    size = min(byte_size(data), capture.max_bytes - capture.bytes)

    if size == 0 do
      capture
    else
      case :file.write(capture.file, binary_part(data, 0, size)) do
        :ok -> %{capture | bytes: capture.bytes + size}
        {:error, reason} -> %{capture | error: reason}
      end
    end
  end

  def append(capture, _data), do: capture

  def finish(nil, _truncated, _seen), do: %{}
  def finish({:error, reason}, _truncated, _seen), do: %{output_retention: %{error: reason}}

  def finish(capture, false, _seen) do
    discard(capture)
    %{}
  end

  def finish(capture, true, seen) do
    close(capture)

    info = %{
      path: Path.relative_to(capture.path, capture.root),
      bytes: capture.bytes,
      total_bytes: seen,
      truncated: capture.bytes < seen
    }

    info = if capture.error, do: Map.put(info, :error, capture.error), else: info
    %{output_retention: info}
  end

  # Raw descriptors belong to the collector and also close if it is killed.
  # A killed collector can leave a bounded reservation for explicit host cleanup.
  def close(%{file: file}), do: :file.close(file)
  def close(_), do: :ok

  def discard(%{path: path, root: root, directory: directory} = capture) do
    close(capture)

    case SafePath.resolve(path, root) do
      {:ok, ^path} ->
        File.rm(path)
        File.rmdir(directory)

      _ ->
        :ok
    end
  end

  def discard(_), do: :ok
end
