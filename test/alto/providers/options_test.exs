defmodule Alto.Providers.OptionsTest do
  use ExUnit.Case, async: true
  alias Alto.Providers.{Anthropic, OpenAICompatible}

  test "stream validation rejects non-HTTP endpoints before delivery" do
    for provider <- [Anthropic, OpenAICompatible] do
      assert {:error, %NimbleOptions.ValidationError{key: :endpoint}} =
               provider.stream(
                 %{},
                 fn _ -> flunk("unexpected delivery") end,
                 model: "test",
                 api_key: "secret",
                 endpoint: "file:///tmp/model"
               )
    end
  end
end
