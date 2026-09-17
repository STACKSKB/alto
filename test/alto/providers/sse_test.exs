defmodule Alto.Providers.SSETest do
  use ExUnit.Case, async: true
  alias Alto.Providers.SSE

  test "library envelope preserves results at every two-chunk boundary and EOF" do
    wire = ": comment\r\nevent: message\r\ndata: héllo\r\ndata: world\r\n\r\ndata: final"

    for split <- 0..byte_size(wire) do
      <<first::binary-size(split), last::binary>> = wire
      assert {:ok, state, a} = SSE.feed(SSE.new(200), first)
      assert {:ok, state, b} = SSE.feed(state, last)
      assert {:ok, c} = SSE.finish(state)
      assert a ++ b ++ c == ["héllo\nworld", "final"]
    end
  end

  test "bounds wire bytes including ignored comments and incomplete fields" do
    for body <- [":" <> String.duplicate("x", 20), "data: " <> String.duplicate("é", 20)] do
      assert {:error, {:sse_event_too_large, 12}} = SSE.feed(SSE.new(12), body)
    end

    assert {:ok, _, ["a", "b"]} = SSE.feed(SSE.new(9), "data: a\n\ndata: b\n\n")
  end

  test "raw JSON fallback preserves blank lines and EOF bytes" do
    raw = "{\n\n\"error\": \"no stream\"}"
    assert {:ok, state, []} = SSE.feed(SSE.new(100), raw)
    assert {:raw, ^raw} = SSE.finish(state)
  end
end
