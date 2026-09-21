defmodule Alto.Tools.ReadFile do
  @moduledoc "Bounded, workspace-confined file reads."

  use Alto.Tool, name: :read_file, execution_mode: :parallel, approval: :never

  alias Alto.Tool.Context
  alias Alto.Tools.Path, as: SafePath

  # The result includes path/offset/metadata and invalid UTF-8 is base64
  # expanded. Leave enough headroom for the runner's default native result
  # bound instead of advertising a content limit that can be rejected after
  # the read has already completed.
  @max_bytes 47_000
  @options_schema [max_bytes: [type: :pos_integer, default: @max_bytes]]

  @impl true
  def schema(opts \\ []) when is_list(opts) do
    limits = validate_options!(opts)

    Alto.Tool.object_schema(
      "Read a bounded byte range from a file inside the workspace.",
      %{
        path: %{
          type: "string",
          description: "Workspace-relative or in-workspace absolute path."
        },
        offset: %{type: "integer", minimum: 0, description: "Byte offset; defaults to 0."},
        limit: %{
          type: "integer",
          minimum: 1,
          maximum: limits.max_bytes,
          description: "Maximum bytes to read."
        }
      },
      ["path"]
    )
  end

  @impl true
  def run(arguments, %Context{} = context, opts \\ []) do
    path = Map.get(arguments, "path")
    offset = Map.get(arguments, "offset", 0)

    with {:ok, limits} <- validate_options(opts),
         limit <- Map.get(arguments, "limit", limits.max_bytes),
         :ok <- valid_range(offset, limit, limits.max_bytes),
         {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, content} <- Alto.BoundedFile.range(resolved, offset, limit + 1) do
      {:ok, encode_content(path, offset, content, limit)}
    end
  end

  defp encode_content(path, offset, content, limit) do
    {content, truncated?} =
      if byte_size(content) > limit,
        do: {binary_part(content, 0, limit), true},
        else: {content, false}

    if String.valid?(content) do
      %{path: path, offset: offset, content: content, truncated: truncated?}
    else
      %{
        path: path,
        offset: offset,
        content_base64: Base.encode64(content),
        encoding: "base64",
        truncated: truncated?
      }
    end
  end

  defp valid_range(offset, limit, max_bytes)
       when is_integer(offset) and offset >= 0 and is_integer(limit) and limit > 0 and
              limit <= max_bytes,
       do: :ok

  defp valid_range(offset, limit, _max_bytes), do: {:error, {:invalid_range, offset, limit}}

  defp validate_options(opts),
    do: Alto.Tool.Options.validate(opts, @options_schema, :invalid_read_file_options)

  defp validate_options!(opts), do: Map.new(NimbleOptions.validate!(opts, @options_schema))
end
