defmodule Alto.ContentTest do
  use ExUnit.Case, async: true

  alias Alto.Content

  test "typed content normalizes to generic persisted blocks and round trips" do
    encoded = Base.encode64(png(12, 8))

    content =
      Content.new([
        Content.text("A small image"),
        Content.image("image/png", encoded, 12, 8)
      ])

    assert {:ok, blocks} = Content.normalize_tool_result(content, 10_000)
    assert JSON.decode!(JSON.encode!(blocks)) == blocks
    assert {:ok, ^content} = Content.decode_transcript(blocks)
  end

  test "ordinary native values never acquire multimodal meaning" do
    lookalike = [
      %{
        "type" => "image",
        "media_type" => "image/png",
        "data" => Base.encode64("x"),
        "width" => 1,
        "height" => 1
      }
    ]

    assert :not_content = Content.normalize_tool_result(lookalike, 10_000)
    assert :not_content = Content.normalize_tool_result(%{blocks: lookalike}, 10_000)
  end

  test "normalization validates blocks and enforces the serialized bound" do
    assert {:error, {:content_too_large, 20}} =
             Content.normalize_tool_result(Content.new([Content.text("long content")]), 20)

    assert {:error, {:invalid_content_block, 0, :invalid_image_base64}} =
             Content.normalize_tool_result(
               Content.new([Content.image("image/png", "not base64", 1, 1)]),
               10_000
             )

    assert {:error, {:invalid_content_block, 0, :image_metadata_mismatch}} =
             Content.normalize_tool_result(
               Content.new([Content.image("image/png", Base.encode64(png(2, 2)), 1, 1)]),
               10_000
             )

    assert {:error, {:invalid_content_block, 0, :unsupported_block}} =
             Content.normalize_tool_result(Content.new([%{text: "ordinary map"}]), 10_000)
  end

  defp png(width, height) do
    signature = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>
    signature <> <<13::32, "IHDR", ihdr::binary, :erlang.crc32(["IHDR", ihdr])::32>>
  end
end
