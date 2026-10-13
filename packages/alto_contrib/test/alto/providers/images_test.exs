defmodule Alto.Contrib.Providers.ImagesTest do
  use ExUnit.Case, async: true
  alias Alto.Contrib.Providers.Images

  defmodule Adapter do
    def run(request) do
      send(self(), {:wire, JSON.decode!(request.body), request})
      response = Req.Response.new(status: 200, headers: [{"content-type", "application/json"}])
      body = Process.get(:image_response)
      {:cont, result} = request.into.({:data, body}, {request, response})
      result
    end
  end

  test "image API requests preserve options and decode named image output" do
    signature = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
    ihdr = <<1::32, 1::32, 8, 2, 0, 0, 0>>
    png = signature <> <<13::32, "IHDR", ihdr::binary, :erlang.crc32(["IHDR", ihdr])::32>>
    data = Base.encode64(png)
    gif = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    Process.put(
      :image_response,
      JSON.encode!(%{
        data: [
          %{b64_json: data, media_type: "image/png"},
          %{b64_json: gif, media_type: "image/gif"}
        ],
        usage: %{total_tokens: 12}
      })
    )

    request = %{
      messages: [
        %{
          "role" => "user",
          "content" => [
            Alto.Content.text("edit this"),
            Alto.Content.image("image/png", data, 1, 1)
          ]
        }
      ],
      tools: []
    }

    opts = [
      model: "image/model",
      api_key: "image-secret",
      headers: [{"x-image-project", "sketch"}],
      input_modalities: ["text", "image"],
      options: %{"size" => "1024x1024"},
      req_options: [adapter: Adapter]
    ]

    assert {:ok, result} = Images.stream(request, fn _ -> :ok end, opts)

    assert [
             %{"type" => "artifact", "name" => "image-1.png", "data" => ^data},
             %{"type" => "artifact", "name" => "image-2.gif", "data" => ^gif}
           ] = result.message

    assert_receive {:wire, body, wire}
    assert Req.Request.get_header(wire, "authorization") == ["Bearer image-secret"]
    assert Req.Request.get_header(wire, "x-image-project") == ["sketch"]
    assert body["size"] == "1024x1024"
    assert body["prompt"] == "edit this"

    assert get_in(body, ["input_references", Access.at(0), "image_url", "url"]) ==
             "data:image/png;base64," <> data

    for key <- [nil, "", :invalid] do
      assert {:ok, _} = Images.stream(request, fn _ -> :ok end, Keyword.put(opts, :api_key, key))
      assert_receive {:wire, _, wire}
      assert Req.Request.get_header(wire, "authorization") == []
      assert Req.Request.get_header(wire, "x-image-project") == ["sketch"]
    end

    assert {:error, :image_metadata_mismatch} =
             Images.Stream.from_response(
               %{"data" => [%{"b64_json" => data, "media_type" => "image/jpeg"}]},
               fn _ -> :ok end
             )

    assert {:error, :image_metadata_mismatch} =
             Alto.Contrib.Providers.Media.output(
               %{
                 "type" => "image_url",
                 "image_url" => %{"url" => "data:image/jpeg;base64," <> data}
               },
               1
             )
  end

  test "partial images are provisional and an incomplete stream fails" do
    state =
      Images.Stream.consume(
        Images.Stream.new(),
        JSON.encode!(%{type: "image_generation.partial_image", b64_json: "AAAA"}),
        fn _ -> :ok end
      )

    assert {:error, :empty_image_response} = Images.Stream.result(state)

    state =
      Images.Stream.consume(
        state,
        JSON.encode!(%{
          type: "image_generation.completed",
          b64_json: Base.encode64("<svg/>"),
          media_type: "image/svg+xml"
        }),
        fn _ -> :ok end
      )

    assert {:ok, %{message: [%{"name" => "image-1.svg"}]}} = Images.Stream.result(state)

    assert {:error, :invalid_image_base64} =
             Images.Stream.from_response(%{"data" => [%{"b64_json" => "!"}]}, fn _ -> :ok end)
  end
end
