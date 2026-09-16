defmodule Alto.Image.Metadata do
  @moduledoc false

  @sof_markers [
    0xC0,
    0xC1,
    0xC2,
    0xC3,
    0xC5,
    0xC6,
    0xC7,
    0xC9,
    0xCA,
    0xCB,
    0xCD,
    0xCE,
    0xCF
  ]

  @spec inspect(binary()) ::
          {:ok, binary(), pos_integer(), pos_integer()} | {:error, term()}
  def inspect(
        <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", ihdr::binary-size(13), crc::32,
          _rest::binary>>
      ) do
    case ihdr do
      <<width::32, height::32, bit_depth, color_type, 0, 0, interlace>>
      when width > 0 and height > 0 and bit_depth > 0 and color_type in [0, 2, 3, 4, 6] and
             interlace in [0, 1] ->
        if :erlang.crc32(["IHDR", ihdr]) == crc,
          do: {:ok, "image/png", width, height},
          else: {:error, :malformed_png}

      _ ->
        {:error, :malformed_png}
    end
  end

  def inspect(<<0x89, "PNG", _rest::binary>>), do: {:error, :malformed_png}
  def inspect(<<0xFF, 0xD8, rest::binary>>), do: jpeg_marker(rest)
  def inspect(_data), do: {:error, :unsupported_image_format}

  defp jpeg_marker(<<0xFF, rest::binary>>) do
    case skip_jpeg_fill(rest) do
      <<marker, tail::binary>> when marker in @sof_markers ->
        jpeg_sof(tail)

      <<marker, tail::binary>> when marker in [0xD8, 0x01] or marker in 0xD0..0xD7 ->
        jpeg_marker(tail)

      <<marker, _tail::binary>> when marker in [0xD9, 0xDA] ->
        {:error, :jpeg_dimensions_not_found}

      <<0x00, _tail::binary>> ->
        {:error, :malformed_jpeg}

      <<_marker, length::16, tail::binary>> when length >= 2 and byte_size(tail) >= length - 2 ->
        <<_segment::binary-size(length - 2), rest::binary>> = tail
        jpeg_marker(rest)

      _ ->
        {:error, :malformed_jpeg}
    end
  end

  defp jpeg_marker(_data), do: {:error, :malformed_jpeg}

  defp skip_jpeg_fill(<<0xFF, rest::binary>>), do: skip_jpeg_fill(rest)
  defp skip_jpeg_fill(rest), do: rest

  defp jpeg_sof(<<length::16, _precision, height::16, width::16, rest::binary>>)
       when length >= 7 and width > 0 and height > 0 and byte_size(rest) >= length - 7,
       do: {:ok, "image/jpeg", width, height}

  defp jpeg_sof(_data), do: {:error, :malformed_jpeg}
end
