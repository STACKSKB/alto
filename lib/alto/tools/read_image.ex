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
    with {:ok, resolved} <- SafePath.resolve(arguments["path"], context.cwd),
         {:ok, source} <- read_bounded(resolved, opts.max_encoded_bytes),
         {:ok, media_type, width, height} <- Metadata.inspect(source, opts),
         {:ok, data, media_type, width, height} <-
           maybe_resize(
             source,
             media_type,
             width,
             height,
             arguments["max_width"],
             arguments["max_height"],
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
    width_scale = if max_width, do: max_width / width, else: 1.0
    height_scale = if max_height, do: max_height / height, else: 1.0
    scale = min(1.0, min(width_scale, height_scale))
    {target_width, target_height} = {max(1, floor(width * scale)), max(1, floor(height * scale))}

    cond do
      {target_width, target_height} == {width, height} ->
        {:ok, data, media_type, width, height}

      is_nil(config.processor) ->
        {:error, :image_resize_unavailable}

      true ->
        result =
          case config.processor do
            fun when is_function(fun, 4) ->
              fun.(data, media_type, target_width, target_height)

            {module, function, extra} ->
              apply(module, function, [data, media_type, target_width, target_height] ++ extra)
          end

        with {:ok, resized} <- result,
             true <-
               4 * div(byte_size(resized) + 2, 3) <= config.max_encoded_bytes or
                 {:error, {:image_encoded_too_large, config.max_encoded_bytes}},
             {:ok, media_type, width, height} <- Metadata.inspect(resized, config),
             true <-
               (width <= target_width and height <= target_height) or
                 {:error, {:image_processor_exceeded_target, target_width, target_height}} do
          {:ok, resized, media_type, width, height}
        end
    end
  end
end
