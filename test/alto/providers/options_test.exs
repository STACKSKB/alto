defmodule Alto.Providers.OptionsTest do
  use ExUnit.Case, async: true
  alias Alto.Providers.{Anthropic, OpenAICompatible}

  test "stream validation identifies invalid fields before delivery" do
    for provider <- [Anthropic, OpenAICompatible] do
      valid = [model: "test", api_key: "secret"]

      for {key, value} <- [
            {:model, nil},
            {:model, ""},
            {:endpoint, "file:///tmp/model"},
            {:timeout, 0},
            {:max_event_bytes, 1.5},
            {:supports_images, :yes}
          ] do
        assert {:error, %NimbleOptions.ValidationError{key: ^key, value: ^value}} =
                 provider.stream(
                   %{},
                   fn _ -> flunk("unexpected delivery") end,
                   Keyword.put(valid, key, value)
                 )
      end

      assert {:error, %NimbleOptions.ValidationError{key: :endpoint}} =
               provider.stream(
                 %{},
                 fn _ -> flunk("unexpected delivery") end,
                 Keyword.merge(valid, endpoint: "invalid", base_url: nil)
               )

      assert {:error, %NimbleOptions.ValidationError{key: :model}} =
               provider.stream(%{}, fn _ -> :ok end, [])
    end

    assert {:error, %NimbleOptions.ValidationError{key: :api_key}} =
             Anthropic.stream(%{}, fn _ -> :ok end, model: "test")

    assert {:error, %NimbleOptions.ValidationError{key: :max_response_bytes, value: 0}} =
             Anthropic.stream(%{}, fn _ -> :ok end,
               model: "test",
               api_key: "secret",
               max_response_bytes: 0
             )

    assert {:error, %NimbleOptions.ValidationError{key: :max_response_bytes, value: 0}} =
             OpenAICompatible.stream(%{}, fn _ -> :ok end, model: "test", max_response_bytes: 0)
  end

  test "model discovery validates its endpoint and independent response limit" do
    assert {:error, %NimbleOptions.ValidationError{key: :endpoint, value: "invalid"}} =
             OpenAICompatible.list_models(models_endpoint: "invalid", base_url: nil)

    assert {:error, %NimbleOptions.ValidationError{key: :max_models_response_bytes, value: 0}} =
             OpenAICompatible.list_models(max_models_response_bytes: 0)

    assert {:error, %NimbleOptions.ValidationError{key: :timeout, value: nil}} =
             OpenAICompatible.list_models(timeout: nil)
  end
end
