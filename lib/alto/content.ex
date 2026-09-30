defmodule Alto.Content do
  @moduledoc """
  Typed content for user messages, model responses and tool results.

  The runner validates typed blocks with `normalize_tool_result/2` before
  adding them to a provider-neutral transcript. Ordinary tool values,
  including maps and lists, are encoded as text.
  """

  @enforce_keys [:blocks]
  defstruct [:blocks]

  alias Alto.Image.Metadata

  @type block :: %{required(String.t()) => String.t() | pos_integer()}
  @type t :: %__MODULE__{blocks: [block()]}

  @max_image_encoded_bytes 8_000_000
  @max_file_encoded_bytes 8_000_000
  @image_limits %{max_dimension: 16_384, max_pixels: 40_000_000}

  @spec new([block()]) :: t()
  def new([_ | _] = blocks), do: %__MODULE__{blocks: blocks}

  @spec text(binary()) :: block()
  def text(text) when is_binary(text), do: %{"type" => "text", "text" => text}

  @spec image(binary(), binary(), pos_integer(), pos_integer()) :: block()
  def image(media_type, data, width, height),
    do: %{
      "type" => "image",
      "media_type" => media_type,
      "data" => data,
      "width" => width,
      "height" => height
    }

  @doc "A named binary file, encoded as base64 (PDF, office document, audio, etc.)."
  def file(name, media_type, data),
    do: %{"type" => "file", "name" => name, "media_type" => media_type, "data" => data}

  @doc "A downloadable output; providers see its name and type rather than opaque bytes."
  def artifact(name, media_type, data),
    do: Map.put(file(name, media_type, data), "type", "artifact")

  @doc "Validate user or model content with an explicit serialized byte limit."
  def normalize(%__MODULE__{} = content, limit), do: normalize_tool_result(content, limit)

  @doc "Text projection for titles, terminal display and text-only integrations."
  def text_value(%__MODULE__{blocks: blocks}), do: text_value(blocks)
  def text_value(value) when is_binary(value), do: value
  def text_value(nil), do: ""

  def text_value(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{"type" => "text", "text" => text} ->
        text

      %{"type" => "image", "media_type" => media, "width" => w, "height" => h} ->
        "[Image · #{media} · #{w} × #{h}]"

      %{"type" => type, "name" => name, "media_type" => media}
      when type in ["file", "artifact"] ->
        "[File · #{name} · #{media}]"
    end)
  end

  def text_value(value), do: inspect(value)

  @doc "Prepend instructions while preserving attached content."
  def prepend(%__MODULE__{} = content, text), do: new([text(text) | content.blocks])
  def prepend(content, text) when is_binary(content), do: text <> content

  @doc "Translate all media blocks with explicit provider capabilities."
  def map_media(%__MODULE__{blocks: blocks}, capabilities, encode) do
    Alto.Result.traverse(blocks, fn
      %{"type" => "image"} = block ->
        if capabilities.images, do: encode.(block), else: {:error, :model_does_not_support_images}

      %{"type" => "file"} = block ->
        if capabilities.files, do: encode.(block), else: {:error, :model_does_not_support_files}

      %{"type" => "artifact", "name" => name, "media_type" => media} ->
        {:ok, text("Generated file: #{name} (#{media})")}

      block ->
        {:ok, block}
    end)
  end

  @doc """
  Normalize typed tool content for the provider-neutral transcript.

  Returns `:not_content` for ordinary tool values, including lookalike maps
  and lists; only `%Alto.Content{}` selects typed content.
  """
  @spec normalize_tool_result(term(), pos_integer()) ::
          :not_content
          | {:ok, [map()]}
          | {:error, term()}
  def normalize_tool_result(value, limit)

  def normalize_tool_result(%__MODULE__{blocks: blocks}, limit)
      when is_integer(limit) and limit > 0 do
    with {:ok, normalized} <- validate_blocks(blocks),
         encoded <- JSON.encode!(normalized),
         true <-
           byte_size(encoded) <= limit or {:error, {:content_too_large, limit}} do
      {:ok, normalized}
    end
  rescue
    error -> {:error, {:invalid_content, Exception.message(error)}}
  end

  def normalize_tool_result(%__MODULE__{}, limit),
    do: {:error, {:invalid_content_limit, limit}}

  def normalize_tool_result(_value, _limit), do: :not_content

  @doc "Validate and wrap provider-neutral content blocks from a transcript."
  @spec decode_transcript(term()) :: :not_content | {:ok, t()} | {:error, term()}
  def decode_transcript([_ | _] = blocks) do
    with {:ok, validated} <- validate_blocks(blocks) do
      {:ok, %__MODULE__{blocks: validated}}
    end
  end

  def decode_transcript(value) when is_list(value), do: {:error, :empty_content}
  def decode_transcript(_value), do: :not_content

  @doc "Translate validated image blocks while preserving text and block order."
  def map_images(%__MODULE__{blocks: blocks}, supports_images, encode) do
    Alto.Result.traverse(blocks, fn
      %{"type" => "image"} when not supports_images ->
        {:error, :model_does_not_support_images}

      %{"type" => "image"} = image ->
        {:ok, encode.(image)}

      text ->
        {:ok, text}
    end)
  end

  defp validate_blocks([_ | _] = blocks) do
    blocks
    |> Enum.with_index()
    |> Alto.Result.traverse(fn {block, index} ->
      case validate_block(block) do
        {:ok, _} = result -> result
        {:error, reason} -> {:error, {:invalid_content_block, index, reason}}
      end
    end)
  end

  defp validate_blocks(_blocks), do: {:error, :empty_content}

  defp validate_block(%{"type" => "text", "text" => text} = block)
       when map_size(block) == 2 and is_binary(text) do
    if String.valid?(text), do: {:ok, block}, else: {:error, :text_must_be_utf8}
  end

  defp validate_block(
         %{
           "type" => "image",
           "media_type" => media_type,
           "data" => data,
           "width" => width,
           "height" => height
         } = block
       )
       when map_size(block) == 5 do
    with :ok <- validate_image(media_type, data, width, height), do: {:ok, block}
  end

  defp validate_block(%{"type" => "artifact"} = block) do
    case validate_block(Map.put(block, "type", "file")) do
      {:ok, _} -> {:ok, block}
      error -> error
    end
  end

  defp validate_block(
         %{"type" => "file", "name" => name, "media_type" => media, "data" => data} = block
       )
       when map_size(block) == 4 do
    with true <-
           (is_binary(name) and byte_size(name) in 1..255 and String.valid?(name) and
              not String.contains?(name, ["/", "\\", <<0>>]) and
              not Regex.match?(~r/[\x00-\x1F\x7F]/u, name) and name not in [".", ".."]) or
             {:error, :invalid_file_name},
         true <-
           (is_binary(media) and byte_size(media) <= 255 and
              Regex.match?(~r/^[a-zA-Z0-9!#$&^_.+-]+\/[a-zA-Z0-9!#$&^_.+-]+$/, media)) or
             {:error, :invalid_media_type},
         true <-
           (is_binary(data) and byte_size(data) <= @max_file_encoded_bytes) or
             {:error, {:file_encoded_too_large, @max_file_encoded_bytes}},
         {:ok, decoded} <- Base.decode64(data),
         true <-
           media != "application/pdf" or String.starts_with?(decoded, "%PDF-") or
             {:error, :invalid_pdf} do
      {:ok, block}
    else
      :error -> {:error, :invalid_file_base64}
      error -> error
    end
  end

  defp validate_block(_block), do: {:error, :unsupported_block}

  defp validate_image(media_type, data, width, height) do
    with true <-
           (is_binary(data) and data != "") or {:error, :image_data_must_be_nonempty_base64},
         true <-
           byte_size(data) <= @max_image_encoded_bytes or
             {:error, {:image_encoded_too_large, @max_image_encoded_bytes}},
         {:ok, decoded} <- decode_image(data),
         {:ok, parsed_media, parsed_width, parsed_height} <-
           Metadata.inspect(decoded, @image_limits),
         true <-
           {parsed_media, parsed_width, parsed_height} === {media_type, width, height} or
             {:error, :image_metadata_mismatch},
         do: :ok
  end

  defp decode_image(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_image_base64}
    end
  end
end
