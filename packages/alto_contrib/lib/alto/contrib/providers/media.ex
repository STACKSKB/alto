defmodule Alto.Contrib.Providers.Media do
  @moduledoc false
  alias Alto.Content

  def output(%{"type" => "image_url", "image_url" => %{"url" => url}}, index),
    do: data_url(url, "image-#{index}", true)

  def output(%{"type" => "file", "file" => %{"filename" => name, "file_data" => url}}, _index),
    do: data_url(url, name, false)

  def output(_, _), do: {:error, :unsupported_model_media}

  defp data_url(url, name, image?) when is_binary(url) and byte_size(url) <= 8_001_000 do
    with [header, data] <- String.split(url, ",", parts: 2),
         [_, media] <- Regex.run(~r/^data:([^;]+);base64$/, header),
         {:ok, bytes} <- Base.decode64(data),
         :ok <- validate_image(bytes, media, image?),
         name = if(image?, do: name <> extension(media), else: name),
         block = Content.artifact(name, media, data),
         {:ok, _} <- Content.decode_transcript([block]) do
      {:ok, block}
    else
      {:error, _} = error -> error
      _ -> {:error, :model_media_must_be_base64_data_url}
    end
  end

  defp data_url(_, _, _), do: {:error, :model_media_must_be_base64_data_url}

  defp validate_image(bytes, media, true) when media in ["image/png", "image/jpeg"] do
    case Alto.Image.Metadata.inspect(bytes, %{max_dimension: 16_384, max_pixels: 40_000_000}) do
      {:ok, ^media, _, _} -> :ok
      {:ok, _, _, _} -> {:error, :image_metadata_mismatch}
      error -> error
    end
  end

  defp validate_image(_bytes, "image/" <> _, true), do: :ok
  defp validate_image(_, _, true), do: {:error, :invalid_image_media_type}
  defp validate_image(_, _, false), do: :ok

  defp extension("image/png"), do: ".png"
  defp extension("image/jpeg"), do: ".jpg"
  defp extension("image/webp"), do: ".webp"
  defp extension("image/gif"), do: ".gif"
  defp extension("image/svg+xml"), do: ".svg"
  defp extension(_), do: ".bin"
end
