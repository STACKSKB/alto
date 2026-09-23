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

  test "model discovery rejects non-HTTP endpoints" do
    assert {:error, %NimbleOptions.ValidationError{key: :endpoint, value: "invalid"}} =
             OpenAICompatible.list_models(models_endpoint: "invalid", base_url: nil)
  end
end
