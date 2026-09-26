defmodule Alto.Tools.ReadFile do
  @moduledoc "Bounded, workspace-confined file reads."

  use Alto.Tool, name: :read_file, execution_mode: :parallel, approval: :never, arguments: true

  alias Alto.Tool.Context
  alias Alto.Tools.Path, as: SafePath

  # The result includes path/offset/metadata and invalid UTF-8 is base64
  # expanded. Leave enough headroom for the runner's default native result
  # bound instead of advertising a content limit that can be rejected after
  # the read has already completed.
  @options_schema [max_bytes: [type: :pos_integer, default: 47_000]]

  @impl true
  def arguments(opts) do
    limits = Alto.Tool.Options.validate!(opts, @options_schema)

    {"Read a bounded byte range from a file inside the workspace.",
     [
       path: [
         type: :string,
         required: true,
         doc: "Workspace-relative or in-workspace absolute path."
       ],
       offset: [
         type: :non_neg_integer,
         default: 0,
         doc: "Byte offset from the start of the file."
       ],
       limit: [
         type: {:in, 1..limits.max_bytes},
         default: limits.max_bytes,
         doc: "Maximum bytes to read."
       ]
     ]}
  end

  @impl true
  def run(arguments, %Context{} = context, _opts \\ []) do
    path = Map.get(arguments, "path")
    offset = arguments["offset"]

    limit = arguments["limit"]

    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
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
end
