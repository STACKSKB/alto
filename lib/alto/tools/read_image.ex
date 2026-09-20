defmodule Alto.Tools.ReadImage do
  @moduledoc "Bounded, workspace-confined PNG/JPEG reads for vision-capable models."

  @behaviour Alto.Tool

  alias Alto.Content
  alias Alto.BoundedFile
  alias Alto.Image.Metadata
  alias Alto.Tool.Context
  alias Alto.Tools.Path, as: SafePath

  @default_max_encoded_bytes 1_000_000
  @hard_max_encoded_bytes 8_000_000
  @default_max_dimension 8_192
  @hard_max_dimension 16_384
  @default_max_pixels 20_000_000
  @hard_max_pixels 40_000_000

  @impl true
  def name(_opts \\ []), do: :read_image

  @impl true
  def schema(_opts \\ []) do
    %{
      description:
        "Read a bounded PNG or JPEG from the workspace for a vision-capable model. Optional dimensions request a resize when a processor backend is configured.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Workspace-relative or in-workspace absolute image path."
          },
          max_width: %{
            type: "integer",
            minimum: 1,
            maximum: @hard_max_dimension,
            description: "Optional maximum output width in pixels."
          },
          max_height: %{
            type: "integer",
            minimum: 1,
            maximum: @hard_max_dimension,
            description: "Optional maximum output height in pixels."
          }
        },
        required: ["path"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def execution_mode(_opts \\ []), do: :parallel

  @impl true
  def approval(_opts \\ []), do: :never

  @impl true
  def run(arguments, context, opts \\ [])

  def run(arguments, %Context{} = context, opts) when is_map(arguments) do
    path = Map.get(arguments, "path")
    requested_width = Map.get(arguments, "max_width")
    requested_height = Map.get(arguments, "max_height")

    with {:ok, config} <- config(opts),
         :ok <- validate_requested_dimensions(requested_width, requested_height),
         {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, source} <- read_bounded(resolved, config.max_encoded_bytes),
         {:ok, media_type, width, height} <- Metadata.inspect(source),
         :ok <- validate_dimensions(width, height, config),
         {:ok, data, media_type, width, height} <-
           maybe_resize(
             source,
             media_type,
             width,
             height,
             requested_width,
             requested_height,
             config
           ),
         :ok <- validate_encoded_size(data, config.max_encoded_bytes) do
      {:ok,
       Content.new([
         Content.image(media_type, Base.encode64(data), width, height)
       ])}
    end
  rescue
    error -> {:error, {:image_reader_exception, Exception.message(error)}}
  end

  def run(_arguments, _context, _opts), do: {:error, :image_arguments_must_be_object}

  defp config(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      max_encoded_bytes = Keyword.get(opts, :max_encoded_bytes, @default_max_encoded_bytes)
      max_dimension = Keyword.get(opts, :max_dimension, @default_max_dimension)
      max_pixels = Keyword.get(opts, :max_pixels, @default_max_pixels)
      processor = Keyword.get(opts, :processor)

      unknown =
        Keyword.keys(opts) -- [:max_encoded_bytes, :max_dimension, :max_pixels, :processor]

      cond do
        unknown != [] ->
          {:error, {:unknown_image_options, unknown}}

        not is_integer(max_encoded_bytes) or max_encoded_bytes <= 0 or
            max_encoded_bytes > @hard_max_encoded_bytes ->
          {:error, {:invalid_max_encoded_bytes, max_encoded_bytes}}

        not is_integer(max_dimension) or max_dimension <= 0 or
            max_dimension > @hard_max_dimension ->
          {:error, {:invalid_max_dimension, max_dimension}}

        not is_integer(max_pixels) or max_pixels <= 0 or max_pixels > @hard_max_pixels ->
          {:error, {:invalid_max_pixels, max_pixels}}

        true ->
          with {:ok, processor} <- normalize_processor(processor) do
            {:ok,
             %{
               max_encoded_bytes: max_encoded_bytes,
               max_dimension: max_dimension,
               max_pixels: max_pixels,
               processor: processor
             }}
          end
      end
    else
      {:error, {:invalid_image_options, opts}}
    end
  end

  defp config(opts), do: {:error, {:invalid_image_options, opts}}

  defp normalize_processor(nil), do: {:ok, nil}

  defp normalize_processor({module, opts}) when is_atom(module) and is_list(opts) do
    validate_processor(module, opts)
  end

  defp normalize_processor(module) when is_atom(module), do: validate_processor(module, [])
  defp normalize_processor(processor), do: {:error, {:invalid_image_processor, processor}}

  defp validate_processor(module, opts) do
    if Keyword.keyword?(opts) and Code.ensure_loaded?(module) and
         function_exported?(module, :resize, 5) do
      {:ok, {module, opts}}
    else
      {:error, {:invalid_image_processor, {module, opts}}}
    end
  end

  defp validate_requested_dimensions(width, height) do
    if valid_optional_dimension?(width) and valid_optional_dimension?(height),
      do: :ok,
      else: {:error, {:invalid_resize_dimensions, width, height}}
  end

  defp valid_optional_dimension?(nil), do: true

  defp valid_optional_dimension?(dimension),
    do: is_integer(dimension) and dimension > 0 and dimension <= @hard_max_dimension

  defp raw_limit(max_encoded_bytes), do: div(max_encoded_bytes, 4) * 3

  defp read_bounded(path, max_encoded_bytes) do
    limit = raw_limit(max_encoded_bytes)

    case BoundedFile.snapshot(path, limit) do
      {:ok, %{content: data}} when is_binary(data) -> {:ok, data}
      {:ok, %{content: nil}} -> {:error, {:image_encoded_too_large, max_encoded_bytes}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_dimensions(width, height, config) do
    cond do
      width > config.max_dimension or height > config.max_dimension ->
        {:error, {:image_dimensions_too_large, config.max_dimension}}

      width * height > config.max_pixels ->
        {:error, {:image_pixel_count_too_large, config.max_pixels}}

      true ->
        :ok
    end
  end

  defp maybe_resize(data, media_type, width, height, max_width, max_height, config) do
    {target_width, target_height} = fit_dimensions(width, height, max_width, max_height)

    if {target_width, target_height} == {width, height} do
      {:ok, data, media_type, width, height}
    else
      resize(data, media_type, target_width, target_height, config)
    end
  end

  defp fit_dimensions(width, height, max_width, max_height) do
    width_scale = if max_width, do: max_width / width, else: 1.0
    height_scale = if max_height, do: max_height / height, else: 1.0
    scale = min(1.0, min(width_scale, height_scale))

    {max(1, floor(width * scale)), max(1, floor(height * scale))}
  end

  defp resize(_data, _media_type, _width, _height, %{processor: nil}),
    do: {:error, :image_resize_unavailable}

  defp resize(data, media_type, target_width, target_height, config) do
    {module, opts} = config.processor

    case module.resize(data, media_type, target_width, target_height, opts) do
      {:ok, resized} when is_binary(resized) ->
        validate_resized(resized, target_width, target_height, config)

      {:error, reason} ->
        {:error, {:image_processor_failed, reason}}

      other ->
        {:error, {:invalid_image_processor_return, other}}
    end
  rescue
    error -> {:error, {:image_processor_exception, Exception.message(error)}}
  end

  defp validate_resized(data, target_width, target_height, config) do
    with :ok <- validate_encoded_size(data, config.max_encoded_bytes),
         {:ok, media_type, width, height} <- Metadata.inspect(data),
         :ok <- validate_dimensions(width, height, config),
         true <-
           (width <= target_width and height <= target_height) or
             {:error, {:image_processor_exceeded_target, target_width, target_height}} do
      {:ok, data, media_type, width, height}
    end
  end

  defp validate_encoded_size(data, max_encoded_bytes) do
    if 4 * div(byte_size(data) + 2, 3) <= max_encoded_bytes,
      do: :ok,
      else: {:error, {:image_encoded_too_large, max_encoded_bytes}}
  end
end
