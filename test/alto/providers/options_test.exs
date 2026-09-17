defmodule Alto.Providers.OptionsTest do
  use ExUnit.Case, async: true
  alias Alto.Providers.{Anthropic, OpenAICompatible}

  test "shared transport validation preserves each adapter's public errors" do
    for provider <- [Anthropic, OpenAICompatible] do
      valid = [model: "test", api_key: "secret"]

      for {key, value, reason} <- [
            {:model, nil, :model_required},
            {:model, "", :model_required},
            {:endpoint, "file:///tmp/model", {:invalid_endpoint, "file:///tmp/model"}},
            {:timeout, 0, {:invalid_timeout, 0}},
            {:max_event_bytes, 1.5, {:invalid_max_event_bytes, 1.5}},
            {:supports_images, :yes, {:invalid_supports_images, :yes}}
          ] do
        assert {:error, ^reason} =
                 provider.stream(
                   %{},
                   fn _ -> flunk("unexpected delivery") end,
                   Keyword.put(valid, key, value)
                 )
      end

      assert {:error, :model_required} = provider.stream(%{}, fn _ -> :ok end, [])
    end

    assert {:error, :api_key_required} = Anthropic.stream(%{}, fn _ -> :ok end, model: "test")

    assert {:error, :invalid_response_limit} =
             Anthropic.stream(%{}, fn _ -> :ok end,
               model: "test",
               api_key: "secret",
               max_response_bytes: 0
             )

    assert {:error, {:invalid_max_response_bytes, 0}} =
             OpenAICompatible.stream(%{}, fn _ -> :ok end, model: "test", max_response_bytes: 0)
  end

  test "model discovery retains its independent option names and errors" do
    assert {:error, {:invalid_models_endpoint, "invalid"}} =
             OpenAICompatible.list_models(models_endpoint: "invalid")

    assert {:error, {:invalid_max_models_response_bytes, 0}} =
             OpenAICompatible.list_models(max_models_response_bytes: 0)

    assert {:error, {:invalid_timeout, nil}} = OpenAICompatible.list_models(timeout: nil)
  end
end
