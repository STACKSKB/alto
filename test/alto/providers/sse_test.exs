defmodule Alto.Providers.SSETest do
  use ExUnit.Case, async: true
  alias Alto.Providers.SSE

  test "bounds unfinished wire data across chunks, including ignored comments" do
    assert {:ok, state, []} = SSE.feed(SSE.new(12), "data: 123")
    assert {:error, {:sse_event_too_large, 12}} = SSE.feed(state, "4567")

    assert {:error, {:sse_event_too_large, 12}} =
             SSE.feed(SSE.new(12), ":" <> String.duplicate("x", 20))
  end

  test "preserves a non-SSE response for provider error handling" do
    raw = "{\n\n\"error\": \"no stream\"}"
    assert {:ok, state, []} = SSE.feed(SSE.new(100), raw)
    assert {:raw, ^raw} = SSE.finish(state)
  end
end
