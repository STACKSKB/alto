defmodule Alto.Providers.Images do
  @moduledoc """
  Bounded image-generation adapter for OpenRouter's `/images` endpoint.

  Configure a dedicated image model with `tools: []`. The current user message
  supplies the prompt and optional reference images. Generated files are returned
  as typed artifacts, so CLI/TUI hosts can save them without printing base64.
  Options such as `size`, `n`, `quality` and `output_format` belong in `:options`.
  """
  @behaviour Alto.Provider
  alias Alto.Providers.{HTTPOptions, StreamEnvelope}
  alias Alto.Content

  def describe(opts),
    do: %{
      protocol: :image_generation,
      model: opts[:model],
      vision: true,
      tools: :none,
      output_modalities: ["image"]
    }

  def list_models(opts),
    do:
      Alto.Providers.OpenAICompatible.list_models(
        Keyword.put_new(opts, :model_query, output_modalities: "image")
      )

  def stream(request, sink, opts) do
    defaults = [max_event_bytes: 8_100_000, max_response_bytes: 16_000_000, timeout: 600_000]
    opts = Keyword.merge(defaults, opts)
    endpoint_opts = HTTPOptions.endpoint_options(opts, "https://openrouter.ai/api/v1", "/images")

    with {:ok, config} <- HTTPOptions.validate(endpoint_opts, HTTPOptions.stream_schema()),
         {:ok, prompt, references} <- input(request.messages) do
      options = Keyword.get(opts, :options, %{})

      body =
        Map.merge(options, %{
          "model" => config.model,
          "prompt" => prompt,
          "stream" => Keyword.get(opts, :streaming, false)
        })

      body = if references == [], do: body, else: Map.put(body, "input_references", references)
      headers = [{"content-type", "application/json"}, {"accept", "text/event-stream"}]

      headers =
        if opts[:api_key],
          do: [{"authorization", "Bearer " <> opts[:api_key]} | headers],
          else: headers

      config = Map.put(config, :req_options, Keyword.get(opts, :req_options, []))

      StreamEnvelope.post(
        config,
        body,
        headers ++ Keyword.get(opts, :headers, []),
        __MODULE__.Stream,
        sink
      )
    end
  end

  defp input(messages) do
    case Enum.find(Enum.reverse(messages), &(&1["role"] == "user")) do
      %{"content" => text} when is_binary(text) and text != "" ->
        {:ok, text, []}

      %{"content" => blocks} ->
        with {:ok, content} <- Content.decode_transcript(blocks),
             true <-
               Enum.all?(content.blocks, &(&1["type"] in ["text", "image"])) or
                 {:error, :image_generation_requires_text_and_images} do
          prompt =
            for(%{"type" => "text", "text" => text} <- content.blocks, do: text)
            |> Enum.join("\n")

          references =
            for %{"type" => "image", "media_type" => media, "data" => data} <- content.blocks,
                do: %{
                  "type" => "image_url",
                  "image_url" => %{"url" => "data:#{media};base64,#{data}"}
                }

          if prompt == "", do: {:error, :image_prompt_required}, else: {:ok, prompt, references}
        end

      _ ->
        {:error, :image_prompt_required}
    end
  end

  defmodule Stream do
    @moduledoc false
    defstruct images: [], usage: nil, error: nil
    def new, do: %__MODULE__{}
    def consume(state, "[DONE]", _sink), do: state

    def consume(state, payload, _sink) do
      case JSON.decode(payload) do
        {:ok, %{"type" => "image_generation.partial_image"}} ->
          state

        {:ok, %{"type" => "image_generation.completed"} = image} ->
          case decode_images([image]) do
            {:ok, images} -> %{state | images: state.images ++ images, usage: image["usage"]}
            {:error, reason} -> %{state | error: reason}
          end

        {:ok, %{"error" => error}} ->
          %{state | error: {:provider_error, error}}

        _ ->
          %{state | error: :invalid_image_response}
      end
    end

    def from_response(%{"data" => [_ | _] = images} = response, _sink) do
      with {:ok, images} <- decode_images(images),
           do: {:ok, %__MODULE__{images: images, usage: response["usage"]}}
    end

    def from_response(%{"error" => error}, _sink), do: {:error, {:provider_error, error}}
    def from_response(_, _), do: {:error, :invalid_image_response}

    def result(%{error: error}) when not is_nil(error), do: {:error, error}
    def result(%{images: []}), do: {:error, :empty_image_response}
    def result(state), do: {:ok, %{message: state.images, tool_calls: [], usage: state.usage}}

    defp image_integrity(bytes, media) when media in ["image/png", "image/jpeg"] do
      case Alto.Image.Metadata.inspect(bytes, %{max_dimension: 16_384, max_pixels: 40_000_000}) do
        {:ok, ^media, _, _} -> :ok
        {:ok, _, _, _} -> {:error, :image_metadata_mismatch}
        error -> error
      end
    end

    defp image_integrity(_, _), do: :ok

    defp decode_images(images) do
      images
      |> Enum.with_index(1)
      |> Alto.Result.traverse(fn
        {%{"b64_json" => data} = image, index}
        when is_binary(data) and byte_size(data) <= 8_000_000 ->
          with {:ok, bytes} <- Base.decode64(data) do
            media = image["media_type"] || Alto.Attachment.media_type(bytes, "image.bin")

            extension =
              case media do
                "image/png" -> ".png"
                "image/jpeg" -> ".jpg"
                "image/webp" -> ".webp"
                "image/svg+xml" -> ".svg"
                _ -> ".bin"
              end

            block = Alto.Content.artifact("image-#{index}" <> extension, media, data)

            with {:ok, _} <- Alto.Content.decode_transcript([block]),
                 :ok <- image_integrity(bytes, media),
                 do: {:ok, block}
          else
            :error -> {:error, :invalid_image_base64}
          end

        _ ->
          {:error, :invalid_image_response}
      end)
    end
  end
end
