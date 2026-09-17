defmodule Alto.BoundedFile do
  @moduledoc "Bounded binary file reads with neutral errors."
  def read(path, max) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result =
          case IO.binread(io, max + 1) do
            {:error, reason} -> {:error, reason}
            :eof -> {:ok, <<>>}
            content when byte_size(content) > max -> {:error, {:too_large, max + 1, max}}
            content -> {:ok, content}
          end

        File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end
end
