defmodule Alto.Providers.MultimodalFilesTest do
  use ExUnit.Case, async: true
  alias Alto.Content
  alias Alto.Providers.{Anthropic, OpenAICompatible}

  defmodule Adapter do
    def run(request) do
      send(self(), {:wire, JSON.decode!(request.body)})
      response = Req.Response.new(status: 200, headers: [{"content-type", "application/json"}])

      {:cont, result} =
        request.into.({:data, Process.get(:multimodal_response)}, {request, response})

      result
    end
  end

  test "PDF uploads map to each provider and file support is checked before HTTP" do
    data = Base.encode64("%PDF-1.7\nreport")
    blocks = [Content.text("read"), Content.file("report.pdf", "application/pdf", data)]
    request = %{messages: [%{"role" => "user", "content" => blocks}], tools: []}

    for provider <- [OpenAICompatible, Anthropic] do
      response =
        if provider == Anthropic,
          do: %{content: [%{type: "text", text: "ok"}], stop_reason: "end_turn", usage: %{}},
          else: %{choices: [%{message: %{content: "ok"}}]}

      Process.put(:multimodal_response, JSON.encode!(response))
      opts = [model: "test", api_key: "unit-test", req_options: [adapter: Adapter]]

      assert {:error, :model_does_not_support_files} =
               provider.stream(request, fn _ -> :ok end, opts)

      refute_receive {:wire, _}

      assert {:ok, _} =
               provider.stream(request, fn _ -> :ok end, Keyword.put(opts, :supports_files, true))

      assert_receive {:wire, body}
      [_, file] = get_in(body, ["messages", Access.at(0), "content"])

      if provider == Anthropic do
        assert file == %{
                 "type" => "document",
                 "title" => "report.pdf",
                 "source" => %{
                   "type" => "base64",
                   "media_type" => "application/pdf",
                   "data" => data
                 }
               }
      else
        assert file == %{
                 "type" => "file",
                 "file" => %{
                   "filename" => "report.pdf",
                   "file_data" => "data:application/pdf;base64," <> data
                 }
               }
      end
    end
  end

  test "opaque generated files are text in requests while remaining binary in history" do
    data = Base.encode64(<<80, 75, 0, 255>>)

    blocks = [
      Content.artifact(
        "report.docx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        data
      )
    ]

    request = %{messages: [%{"role" => "assistant", "content" => blocks}], tools: []}

    for provider <- [OpenAICompatible, Anthropic] do
      response =
        if provider == Anthropic,
          do: %{content: [%{type: "text", text: "ok"}], stop_reason: "end_turn", usage: %{}},
          else: %{choices: [%{message: %{content: "ok"}}]}

      Process.put(:multimodal_response, JSON.encode!(response))

      assert {:ok, _} =
               provider.stream(request, fn _ -> :ok end,
                 model: "test",
                 api_key: "test",
                 req_options: [adapter: Adapter]
               )

      assert_receive {:wire, body}

      assert [%{"type" => "text", "text" => text}] =
               get_in(body, ["messages", Access.at(0), "content"])

      assert text =~ "report.docx"
      refute JSON.encode!(body) =~ data
    end
  end

  test "Anthropic rejects unsupported uploaded binary types explicitly" do
    request = %{
      messages: [
        %{
          "role" => "user",
          "content" => [
            Content.file("report.docx", "application/octet-stream", Base.encode64(<<255>>))
          ]
        }
      ],
      tools: []
    }

    assert {:error, {:unsupported_anthropic_file_type, "application/octet-stream"}} =
             Anthropic.stream(request, fn _ -> :ok end,
               model: "test",
               api_key: "test",
               supports_files: true,
               req_options: [adapter: Adapter]
             )

    refute_receive {:wire, _}
  end

  test "chat completion image output becomes a downloadable artifact" do
    signature = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
    ihdr = <<1::32, 1::32, 8, 2, 0, 0, 0>>
    png = signature <> <<13::32, "IHDR", ihdr::binary, :erlang.crc32(["IHDR", ihdr])::32>>
    data = Base.encode64(png)

    response = %{
      "choices" => [
        %{
          "message" => %{
            "content" => "Here it is",
            "images" => [
              %{
                "type" => "image_url",
                "image_url" => %{"url" => "data:image/png;base64," <> data}
              }
            ]
          }
        }
      ]
    }

    assert {:ok, state} =
             Alto.Providers.OpenAICompatible.Stream.from_response(response, fn _ -> :ok end)

    assert {:ok,
            %{message: [_, %{"type" => "artifact", "name" => "image-1.png", "data" => ^data}]}} =
             Alto.Providers.OpenAICompatible.Stream.result(state)
  end

  test "audio cannot bypass model gating as a generic file and uses native audio parts" do
    data = Base.encode64("RIFF")

    request = %{
      messages: [%{"role" => "user", "content" => [Content.file("clip.wav", "audio/wav", data)]}],
      tools: []
    }

    Process.put(:multimodal_response, JSON.encode!(%{choices: [%{message: %{content: "ok"}}]}))
    opts = [model: "audio", supports_files: true, req_options: [adapter: Adapter]]

    assert {:error, :model_does_not_support_audio} =
             OpenAICompatible.stream(request, fn _ -> :ok end, opts)

    refute_receive {:wire, _}

    assert {:ok, _} =
             OpenAICompatible.stream(
               request,
               fn _ -> :ok end,
               Keyword.put(opts, :input_modalities, ["text", "audio"])
             )

    assert_receive {:wire, body}

    assert [%{"type" => "input_audio", "input_audio" => %{"data" => ^data, "format" => "wav"}}] =
             get_in(body, ["messages", Access.at(0), "content"])

    image_file = Content.file("clip.gif", "image/gif", Base.encode64("GIF89a"))
    request = put_in(request.messages, [%{"role" => "user", "content" => [image_file]}])

    assert {:error, :model_does_not_support_images} =
             OpenAICompatible.stream(request, fn _ -> :ok end, opts)

    video = Content.file("clip.mp4", "video/mp4", Base.encode64("video"))
    request = put_in(request.messages, [%{"role" => "user", "content" => [video]}])

    assert {:error, :model_does_not_support_video} =
             OpenAICompatible.stream(request, fn _ -> :ok end, opts)

    refute_receive {:wire, _}
  end
end
