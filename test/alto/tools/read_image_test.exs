defmodule Alto.Tools.ReadImageTest do
  use ExUnit.Case, async: true

  alias Alto.Content
  alias Alto.Tool.Context
  alias Alto.Tools.ReadImage

  defmodule Processor do
    @behaviour Alto.Image.Processor

    @impl true
    def resize(_data, media_type, width, height, opts) do
      send(Keyword.fetch!(opts, :owner), {:resize, media_type, width, height})
      {:ok, Keyword.fetch!(opts, :output)}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-images-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, context: %Context{session_id: "test", cwd: root}}
  end

  test "rejects malformed host options before reading a file", %{context: context} do
    assert {:error, {:invalid_image_options, :invalid}} =
             ReadImage.run(%{"path" => "missing.png"}, context, :invalid)
  end

  test "reads PNG bytes into typed image content", %{root: root, context: context} do
    png = png(320, 200)
    File.write!(Path.join(root, "image.png"), png)

    assert {:ok,
            %Content{
              blocks: [
                %{
                  "type" => "image",
                  "media_type" => "image/png",
                  "data" => encoded,
                  "width" => 320,
                  "height" => 200
                }
              ]
            }} = ReadImage.run(%{"path" => "image.png"}, context)

    assert Base.decode64!(encoded) == png
  end

  test "sniffs JPEG dimensions without trusting the extension", %{root: root, context: context} do
    jpeg = jpeg(640, 480)
    File.write!(Path.join(root, "not-a-jpeg.bin"), jpeg)

    assert {:ok,
            %Content{
              blocks: [
                %{
                  "type" => "image",
                  "media_type" => "image/jpeg",
                  "width" => 640,
                  "height" => 480
                }
              ]
            }} =
             ReadImage.run(%{"path" => "not-a-jpeg.bin"}, context)
  end

  test "rejects malformed files, oversized encoding, and decoded dimensions", %{
    root: root,
    context: context
  } do
    File.write!(Path.join(root, "bad.png"), <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>)
    assert {:error, :malformed_png} = ReadImage.run(%{"path" => "bad.png"}, context)

    File.write!(Path.join(root, "bad.jpg"), <<0xFF, 0xD8, 0xFF, 0xC0, 0, 17, 8>>)
    assert {:error, :malformed_jpeg} = ReadImage.run(%{"path" => "bad.jpg"}, context)

    File.write!(Path.join(root, "huge.png"), png(9_000, 2))

    assert {:error, {:image_dimensions_too_large, 8_192}} =
             ReadImage.run(%{"path" => "huge.png"}, context)

    File.write!(Path.join(root, "pixels.png"), png(5_000, 5_000))

    assert {:error, {:image_pixel_count_too_large, 20_000_000}} =
             ReadImage.run(%{"path" => "pixels.png"}, context)

    File.write!(Path.join(root, "large.jpg"), jpeg(10, 10) <> :binary.copy(<<0>>, 100))

    assert {:error, {:image_encoded_too_large, 100}} =
             ReadImage.run(%{"path" => "large.jpg"}, context, max_encoded_bytes: 100)
  end

  test "keeps image reads inside the workspace", %{context: context} do
    assert {:error, {:path_outside_workspace, "../outside.png"}} =
             ReadImage.run(%{"path" => "../outside.png"}, context)
  end

  test "resize is explicit and a configured backend is revalidated", %{
    root: root,
    context: context
  } do
    File.write!(Path.join(root, "image.png"), png(400, 200))

    assert {:error, :image_resize_unavailable} =
             ReadImage.run(%{"path" => "image.png", "max_width" => 100}, context)

    output = png(100, 50)

    assert {:ok, %Content{blocks: [%{"type" => "image", "width" => 100, "height" => 50}]}} =
             ReadImage.run(
               %{"path" => "image.png", "max_width" => 100},
               context,
               processor: {Processor, owner: self(), output: output}
             )

    assert_receive {:resize, "image/png", 100, 50}

    assert {:error, {:image_processor_exceeded_target, 100, 50}} =
             ReadImage.run(
               %{"path" => "image.png", "max_width" => 100},
               context,
               processor: {Processor, owner: self(), output: png(101, 50)}
             )
  end

  defp png(width, height) do
    signature = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>
    crc = :erlang.crc32(["IHDR", ihdr])
    signature <> <<13::32, "IHDR", ihdr::binary, crc::32>>
  end

  defp jpeg(width, height) do
    components = <<3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    <<0xFF, 0xD8, 0xFF, 0xC0, 17::16, 8, height::16, width::16, components::binary, 0xFF, 0xD9>>
  end
end
