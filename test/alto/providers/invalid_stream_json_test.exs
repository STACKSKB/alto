defmodule Alto.Providers.InvalidStreamJSONTest do
  use ExUnit.Case, async: true

  test "both stream parsers report malformed JSON without exceptions or response bodies" do
    for stream <- [Alto.Providers.OpenAICompatible.Stream, Alto.Providers.Anthropic.Stream],
        payload <- ["not-json PRIVATE-BODY", "{\"private\":", "\"\\uZZZZ PRIVATE-BODY\""] do
      state = stream.consume(stream.new(), payload, fn _ -> flunk("unexpected stream output") end)
      assert {:error, {:invalid_stream_json, message}} = stream.result(state)
      assert message == "Invalid JSON in provider stream"
      refute message =~ "PRIVATE-BODY"
    end
  end
end
