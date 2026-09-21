defmodule Alto.BoundedFile do
  @moduledoc "Bounded reads and streaming fingerprints with descriptor-owned metadata."
  @chunk_size 64 * 1024

  def read(path, max) when is_integer(max) and max >= 0 do
    with {:ok, content} <- range(path, 0, max + 1) do
      if byte_size(content) > max,
        do: {:error, {:too_large, max + 1, max}},
        else: {:ok, content}
    end
  end

  @doc "Read up to length bytes at an offset, returning empty content past EOF."
  def range(path, offset, length)
      when is_integer(offset) and offset >= 0 and is_integer(length) and length > 0 do
    with_file(path, fn io ->
      with {:ok, _position} <- :file.position(io, offset), do: read_prefix(io, length)
    end)
  end

  @doc "Read a regular file up to the cap; nil content indicates an oversized file."
  def snapshot(path, max) when is_integer(max) and max >= 0 do
    with_regular_file(path, fn io, stat ->
      with {:ok, content} <- read_prefix(io, max + 1) do
        if byte_size(content) > max,
          do: {:ok, %{stat: stat, bytes: stat.size, content: nil, fingerprint: nil}},
          else:
            {:ok,
             %{
               stat: stat,
               bytes: byte_size(content),
               content: content,
               fingerprint: :crypto.hash(:sha256, content)
             }}
      end
    end)
  end

  @doc "Hash the entire regular file, retaining content only if it fits the cap."
  def fingerprint_snapshot(path, max) when is_integer(max) and max >= 0 do
    with_regular_file(path, fn io, stat ->
      with {:ok, snapshot} <- hash_chunks(io, max, :crypto.hash_init(:sha256), 0, []),
           do: {:ok, Map.put(snapshot, :stat, stat)}
    end)
  end

  def digest(path) do
    with {:ok, snapshot} <- fingerprint_snapshot(path, 0),
         do: {:ok, Map.take(snapshot, [:fingerprint, :bytes])}
  end

  defp hash_chunks(io, max, hash, bytes, parts) do
    case :file.read(io, @chunk_size) do
      {:ok, chunk} ->
        size = bytes + byte_size(chunk)
        kept = if parts != nil and size <= max, do: [chunk | parts], else: nil
        hash_chunks(io, max, :crypto.hash_update(hash, chunk), size, kept)

      :eof ->
        content = if parts, do: parts |> Enum.reverse() |> IO.iodata_to_binary(), else: nil
        {:ok, %{content: content, bytes: bytes, fingerprint: :crypto.hash_final(hash)}}

      {:error, _} = error ->
        error
    end
  end

  defp read_prefix(io, limit) do
    case IO.binread(io, limit) do
      {:error, _} = error -> error
      :eof -> {:ok, <<>>}
      content -> {:ok, content}
    end
  end

  defp with_regular_file(path, fun) do
    with_file(path, fn io ->
      with {:ok, info} <- :file.read_file_info(io),
           stat = File.Stat.from_record(info),
           true <- stat.type == :regular or {:error, {:not_a_file, path}},
           do: fun.(io, stat)
    end)
  end

  defp with_file(path, fun) do
    with {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        fun.(io)
      after
        File.close(io)
      end
    end
  end
end
