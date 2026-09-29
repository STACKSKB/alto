defmodule Alto.Session.LogScan do
  @moduledoc false
  @chunk 65_536

  # One descriptor owns prefix validation and appended-line replay. Complete
  # lines alone advance the digest/offset; a torn final record is retried later.
  def fold(path, max_bytes, offset, digest, initial, fallback, fun, opts \\ []) do
    case File.open(path, [:read, :binary, :raw], fn file ->
           with {:ok, info} <- :file.read_file_info(file),
                stat <- File.Stat.from_record(info),
                true <- stat.type == :regular or {:error, :not_regular},
                true <- stat.size <= max_bytes or {:error, {:too_large, stat.size, max_bytes}} do
             prefix =
               if offset <= stat.size,
                 do: hash_prefix(file, offset, :crypto.hash_init(:sha256)),
                 else: :invalid

             {state, start, hash} =
               case prefix do
                 {:ok, hash} ->
                   if hex(hash) == digest,
                     do: {initial, offset, hash},
                     else: {fallback, 0, :crypto.hash_init(:sha256)}

                 _ ->
                   {fallback, 0, :crypto.hash_init(:sha256)}
               end

             with {:ok, _} <- :file.position(file, start),
                  do:
                    replay(
                      file,
                      stat.size - start,
                      state,
                      start,
                      hash,
                      "",
                      fun,
                      Keyword.get(opts, :complete_only, true)
                    )
           end
         end) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp hash_prefix(_, 0, hash), do: {:ok, hash}

  defp hash_prefix(file, left, hash) do
    case :file.read(file, min(left, @chunk)) do
      {:ok, bytes} -> hash_prefix(file, left - byte_size(bytes), :crypto.hash_update(hash, bytes))
      _ -> :invalid
    end
  end

  defp replay(_, 0, state, offset, hash, tail, fun, false) when tail != "" do
    with {:ok, state} <- fun.(tail, state), do: {:ok, state, offset, hex(hash)}
  end

  defp replay(_, 0, state, offset, hash, _tail, _fun, _), do: {:ok, state, offset, hex(hash)}

  defp replay(file, left, state, offset, hash, tail, fun, complete_only) do
    case :file.read(file, min(left, @chunk)) do
      {:ok, bytes} ->
        parts = String.split(tail <> bytes, "\n")
        {tail, lines} = List.pop_at(parts, -1)

        result =
          Enum.reduce_while(lines, {:ok, state, offset, hash}, fn line, {:ok, acc, pos, hash} ->
            case if(line == "", do: {:ok, acc}, else: fun.(line, acc)) do
              {:ok, next} ->
                {:cont,
                 {:ok, next, pos + byte_size(line) + 1, :crypto.hash_update(hash, [line, "\n"])}}

              error ->
                {:halt, error}
            end
          end)

        with {:ok, next, pos, hash} <- result,
             do: replay(file, left - byte_size(bytes), next, pos, hash, tail, fun, complete_only)

      :eof ->
        {:error, :session_changed_during_read}

      error ->
        error
    end
  end

  defp hex(hash), do: Base.encode16(:crypto.hash_final(hash), case: :lower)
end
