defmodule Alto.EventBuffer do
  @moduledoc false
  defstruct queue: {[], []}, size: 0, bytes: 0

  def push(buffer, value, limit, byte_limit \\ 8_000_000)
      when is_integer(limit) and limit >= 0 and is_integer(byte_limit) and byte_limit >= 0 do
    bytes = :erlang.external_size(value)

    buffer = %{
      buffer
      | queue: :queue.in({value, bytes}, buffer.queue),
        size: buffer.size + 1,
        bytes: buffer.bytes + bytes
    }

    trim(buffer, limit, byte_limit, 0)
  end

  def to_list(buffer), do: Enum.map(:queue.to_list(buffer.queue), &elem(&1, 0))

  defp trim(buffer, count, bytes, dropped) when buffer.size <= count and buffer.bytes <= bytes,
    do: {buffer, dropped}

  defp trim(buffer, count, bytes, dropped) do
    {{:value, {_, removed}}, queue} = :queue.out(buffer.queue)

    trim(
      %{buffer | queue: queue, size: buffer.size - 1, bytes: buffer.bytes - removed},
      count,
      bytes,
      dropped + 1
    )
  end
end
