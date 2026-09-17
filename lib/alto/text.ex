defmodule Alto.Text do
  @moduledoc "UTF-8 byte limits, distinct from display width and grapheme clipping."

  def prefix(text, limit) when is_binary(text) and is_integer(limit) and limit >= 0 do
    bytes = binary_part(text, 0, min(byte_size(text), limit))

    case :unicode.characters_to_binary(bytes) do
      value when is_binary(value) -> value
      {_, valid, _} -> valid
    end
  end

  def truncate(text, limit, marker) when is_binary(text) and is_binary(marker) and limit >= 0 do
    if byte_size(text) <= limit do
      text
    else
      marker = prefix(marker, limit)
      prefix(text, limit - byte_size(marker)) <> marker
    end
  end
end
