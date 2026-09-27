defmodule Alto.Tools.ReadImage do
  @moduledoc "Bounded, workspace-confined PNG/JPEG reads for vision-capable models."

  use Alto.Tool, name: :read_image, execution_mode: :parallel, approval: :never, arguments: true

  alias Alto.Content
  alias Alto.BoundedFile
  alias Alto.Image.Metadata
  alias Alto.Tools.Path, as: SafePath

  @hard_max_dimension 16_384

  @impl true
  def options,
    do: %{
      max_encoded_bytes: 1_000_000,
      max_dimension: 8_192,
      max_pixels: 20_000_000,
      processor: nil
    }

  @impl true
  def arguments(_opts) do
    {"Read a bounded PNG or JPEG from the workspace for a vision-capable model. Optional dimensions request a resize when a processor backend is configured.",
     [
       path: [type: :string, required: true],
       max_width: [type: {:or, [{:in, 1..@hard_max_dimension}, {:in, [nil]}]}],
       max_height: [type: {:or, [{:in, 1..@hard_max_dimension}, {:in, [nil]}]}]
     ]}
  end

  @impl true
  def run(arguments, context, opts \\ [])

  def run(arguments, %{} = context, opts) when is_map(arguments) do
    path = Map.get(arguments, "path")
    requested_width = Map.get(arguments, "max_width")
    requested_height = Map.get(arguments, "max_height")

    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, source} <- read_bounded(resolved, opts.max_encoded_bytes),
         {:ok, media_type, width, height} <- Metadata.inspect(source, opts),
         {:ok, data, media_type, width, height} <-
           maybe_resize(
             source,
             media_type,
             width,
             height,
             requested_width,
             requested_height,
             opts
           ) do
      {:ok,
       Content.new([
         Content.image(media_type, Base.encode64(data), width, height)
       ])}
    end
  rescue
    error -> {:error, {:image_reader_exception, Exception.message(error)}}
  end

  def run(_arguments, _context, _opts), do: {:error, :image_arguments_must_be_object}

  defp read_bounded(path, max_encoded_bytes) do
    limit = div(max_encoded_bytes, 4) * 3

    case BoundedFile.snapshot(path, limit) do
      {:ok, %{content: data}} when is_binary(data) -> {:ok, data}
      {:ok, %{content: nil}} -> {:error, {:image_encoded_too_large, max_encoded_bytes}}
      {:error, reason} -> {:error, reason}
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
    result =
      case config.processor do
        fun when is_function(fun, 4) ->
          fun.(data, media_type, target_width, target_height)

        {module, function, extra} ->
          apply(module, function, [data, media_type, target_width, target_height] ++ extra)
      end

    with {:ok, resized} <- result,
         do: validate_resized(resized, target_width, target_height, config)
  end

  defp validate_resized(data, target_width, target_height, config) do
    with :ok <- validate_encoded_size(data, config.max_encoded_bytes),
         {:ok, media_type, width, height} <- Metadata.inspect(data, config),
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
