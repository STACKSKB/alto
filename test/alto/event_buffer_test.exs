defmodule Alto.EventBufferTest do
  use ExUnit.Case, async: true
  alias Alto.EventBuffer

  test "bounded retention matches a list oracle through growth, shrinkage and zero capacity" do
    Enum.reduce(1..2000, {%EventBuffer{}, [], 0}, fn n, {buffer, expected, discarded} ->
      limit = rem(n, 101)
      all = expected ++ [n]
      retained = if limit == 0, do: [], else: Enum.take(all, -limit)
      {next, dropped} = EventBuffer.push(buffer, n, limit)
      assert EventBuffer.to_list(next) == retained
      assert next.size == length(retained)
      assert discarded + dropped + next.size == n
      {next, retained, discarded + dropped}
    end)
  end

  test "byte limits retain a contiguous suffix and count oversized drops" do
    a = String.duplicate("a", 100)
    b = String.duplicate("b", 100)
    bytes = :erlang.external_size(a)
    {buffer, 0} = EventBuffer.push(%EventBuffer{}, a, 1000, bytes)
    {buffer, 1} = EventBuffer.push(buffer, b, 1000, bytes)
    assert EventBuffer.to_list(buffer) == [b]
    assert buffer.bytes == bytes
    {buffer, 2} = EventBuffer.push(buffer, a <> b, 1000, bytes)
    assert buffer.size == 0
    assert buffer.bytes == 0
    {buffer, 0} = EventBuffer.push(buffer, a, 1000, bytes)
    assert EventBuffer.to_list(buffer) == [a]
  end
end
