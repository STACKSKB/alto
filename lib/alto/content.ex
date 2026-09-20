defmodule Alto.Content do
  @moduledoc """
  Typed model-facing content returned by tools.

  A `%Content{}` is deliberately distinct from ordinary tool values. The
  runner must call `normalize_tool_result/2` before placing it in a transcript;
  maps and lists returned by other tools continue through the legacy JSON-text
  path. Normalized blocks contain only JSON-compatible values and survive
  session persistence without provider-specific fields.
  """

  @enforce_keys [:blocks]
  defstruct [:blocks]

  alias Alto.Image.Metadata

  defmodule Text do
    @moduledoc false
    @enforce_keys [:text]
    defstruct [:text]

    @type t :: %__MODULE__{text: binary()}
  end

  defmodule Image do
    @moduledoc false
    @enforce_keys [:media_type, :data, :width, :height]
    defstruct [:media_type, :data, :width, :height]

    @type t :: %__MODULE__{
            media_type: binary(),
            data: binary(),
            width: pos_integer(),
            height: pos_integer()
          }
  end

  @type block ::
          %Text{text: binary()}
          | %Image{
              media_type: binary(),
              data: binary(),
              width: pos_integer(),
              height: pos_integer()
            }
  @type t :: %__MODULE__{blocks: [block()]}

  @media_types ["image/png", "image/jpeg"]
  @max_image_encoded_bytes 8_000_000
  @max_image_dimension 16_384
  @max_image_pixels 40_000_000

  @spec new([block()]) :: t()
  def new([_ | _] = blocks), do: %__MODULE__{blocks: blocks}

  @spec text(binary()) :: Text.t()
  def text(text) when is_binary(text), do: %Text{text: text}

  @spec image(binary(), binary(), pos_integer(), pos_integer()) :: Image.t()
  def image(media_type, data, width, height),
    do: %Image{media_type: media_type, data: data, width: width, height: height}

  @doc """
  Normalize typed tool content for the provider-neutral transcript.

  `:not_content` is returned for every value that is not an `%Alto.Content{}`,
  including lookalike maps and lists, so existing native tool values retain
  their legacy string/JSON behavior.
  """
  @spec normalize_tool_result(term(), pos_integer()) ::
          :not_content
          | {:ok, [map()]}
          | {:error, term()}
  def normalize_tool_result(value, limit)

  def normalize_tool_result(%__MODULE__{blocks: blocks}, limit)
      when is_integer(limit) and limit > 0 do
    with {:ok, normalized} <- normalize_blocks(blocks),
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

  @doc "Rehydrate and validate provider-neutral content blocks from a transcript."
  @spec decode_transcript(term()) :: :not_content | {:ok, t()} | {:error, term()}
  def decode_transcript([_ | _] = blocks) do
    with {:ok, typed} <- map_blocks(blocks, &decode_block/1) do
      {:ok, %__MODULE__{blocks: typed}}
    end
  end

  def decode_transcript(value) when is_list(value), do: {:error, :empty_content}
  def decode_transcript(_value), do: :not_content

  defp normalize_blocks([_ | _] = blocks), do: map_blocks(blocks, &normalize_block/1)

  defp normalize_blocks(_blocks), do: {:error, :empty_content}

  defp normalize_block(%Text{text: text}) when is_binary(text) do
    if String.valid?(text),
      do: {:ok, %{"type" => "text", "text" => text}},
      else: {:error, :text_must_be_utf8}
  end

  defp normalize_block(%Image{} = image) do
    with :ok <- validate_image(image) do
      {:ok,
       %{
         "type" => "image",
         "media_type" => image.media_type,
         "data" => image.data,
         "width" => image.width,
         "height" => image.height
       }}
    end
  end

  defp normalize_block(_block), do: {:error, :unsupported_block}

  defp map_blocks(blocks, fun) do
    blocks
    |> Enum.with_index()
    |> Alto.Result.traverse(fn {block, index} ->
      case fun.(block) do
        {:ok, _} = result -> result
        {:error, reason} -> {:error, {:invalid_content_block, index, reason}}
      end
    end)
  end

  defp decode_block(%{"type" => "text", "text" => text} = block)
       when map_size(block) == 2 and is_binary(text) do
    if String.valid?(text), do: {:ok, %Text{text: text}}, else: {:error, :text_must_be_utf8}
  end

  defp decode_block(
         %{
           "type" => "image",
           "media_type" => media_type,
           "data" => data,
           "width" => width,
           "height" => height
         } = block
       )
       when map_size(block) == 5 do
    image = %Image{media_type: media_type, data: data, width: width, height: height}
    with :ok <- validate_image(image), do: {:ok, image}
  end

  defp decode_block(_block), do: {:error, :unsupported_block}

  defp validate_image(%Image{media_type: media_type, data: data, width: width, height: height}) do
    cond do
      media_type not in @media_types ->
        {:error, {:unsupported_media_type, media_type}}

      not is_binary(data) or data == "" ->
        {:error, :image_data_must_be_nonempty_base64}

      byte_size(data) > @max_image_encoded_bytes ->
        {:error, {:image_encoded_too_large, @max_image_encoded_bytes}}

      not is_integer(width) or width <= 0 or not is_integer(height) or height <= 0 ->
        {:error, :invalid_image_dimensions}

      width > @max_image_dimension or height > @max_image_dimension ->
        {:error, {:image_dimensions_too_large, @max_image_dimension}}

      width * height > @max_image_pixels ->
        {:error, {:image_pixel_count_too_large, @max_image_pixels}}

      true ->
        validate_encoded_image(data, media_type, width, height)
    end
  end

  defp validate_encoded_image(data, expected_media_type, expected_width, expected_height) do
    with {:ok, decoded} <- decode_image(data),
         {:ok, media_type, width, height} <- Metadata.inspect(decoded),
         true <-
           {media_type, width, height} ==
             {expected_media_type, expected_width, expected_height} or
             {:error, :image_metadata_mismatch} do
      :ok
    end
  end

  defp decode_image(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_image_base64}
    end
  end
end
