defmodule Alto.InputModalitiesTest do
  use ExUnit.Case, async: true
  alias Alto.{Content, InputModalities, Provider}
  alias Alto.Harness.ProviderProfile

  defmodule CaptureProvider do
    @behaviour Alto.Provider
    def describe(opts), do: %{input_modalities: InputModalities.configured(opts)}

    def stream(request, _sink, opts) do
      send(opts[:owner], {:dispatched, request})
      {:ok, %{message: "ok", tool_calls: []}}
    end
  end

  defmodule CodexClient do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:request, "model/list", _, _}, _from, owner) do
      {:reply,
       {:ok,
        %{
          "data" => [
            %{"id" => "text", "model" => "text", "inputModalities" => ["text"]},
            %{"id" => "audio", "model" => "audio", "inputModalities" => ["text", "audio"]}
          ]
        }}, owner}
    end

    def handle_call({:request, method, params, _}, _from, owner) do
      send(owner, {:codex_dispatch, method, params})

      response =
        if method == "turn/start",
          do: %{"turn" => %{"id" => "turn"}},
          else: %{"thread" => %{"id" => "thread"}}

      {:reply, {:ok, response}, owner}
    end
  end

  test "selected catalog capabilities gate initial, historical and tool media before dispatch" do
    profile = %ProviderProfile{
      id: "capture",
      provider:
        {CaptureProvider,
         model: "vision", supports_images: true, supports_files: true, owner: self()},
      models: [
        %{id: "vision", input_modalities: ["text", "image"]},
        %{id: "text", input_modalities: ["text"]}
      ]
    }

    image = image()

    for role <- ["user", "tool"] do
      request = %{messages: [%{"role" => role, "content" => [image]}], tools: []}
      {module, opts} = ProviderProfile.runtime_provider(profile, "text")

      assert {:error, :model_does_not_support_images} =
               Provider.stream(module, request, fn _ -> :ok end, opts)

      refute_receive {:dispatched, _}
      {module, opts} = ProviderProfile.runtime_provider(profile, "vision")
      assert {:ok, _} = Provider.stream(module, request, fn _ -> :ok end, opts)
      assert_receive {:dispatched, ^request}
      {module, opts} = ProviderProfile.runtime_provider(profile, "unknown")

      assert {:error, :model_does_not_support_images} =
               Provider.stream(module, request, fn _ -> :ok end, opts)

      refute_receive {:dispatched, _}
    end

    artifact = Content.artifact("image.png", "image/png", image["data"])
    {module, opts} = ProviderProfile.runtime_provider(profile, "text")

    assert {:ok, _} =
             Provider.stream(
               module,
               %{messages: [%{"content" => [artifact]}]},
               fn _ -> :ok end,
               opts
             )

    assert_receive {:dispatched, _}
  end

  test "Codex checks discovered model modalities before sending a turn" do
    client = start_supervised!({CodexClient, self()})
    audio = Content.new([Content.file("clip.wav", "audio/wav", Base.encode64("RIFF"))])

    assert {:error, :model_does_not_support_audio} =
             Alto.Codex.Backend.start_turn(client, "thread", audio,
               cwd: File.cwd!(),
               model: "text"
             )

    refute_receive {:codex_dispatch, _, _}

    assert {:ok, _} =
             Alto.Codex.Backend.start_turn(client, "thread", audio,
               cwd: File.cwd!(),
               model: "audio"
             )

    assert_receive {:codex_dispatch, "turn/start",
                    %{
                      "input" => [%{"type" => "audio", "url" => "data:audio/wav;base64,UklGRg=="}]
                    }}
  end

  defp image do
    signature = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
    ihdr = <<1::32, 1::32, 8, 2, 0, 0, 0>>
    png = signature <> <<13::32, "IHDR", ihdr::binary, :erlang.crc32(["IHDR", ihdr])::32>>
    Content.image("image/png", Base.encode64(png), 1, 1)
  end
end
