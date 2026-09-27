defmodule Alto.Tools.ReadFile do
  @moduledoc "Bounded, workspace-confined file reads."

  use Alto.Tool, name: :read_file, execution_mode: :parallel, approval: :never, arguments: true

  alias Alto.Tools.Path, as: SafePath

  # The result includes path/offset/metadata and invalid UTF-8 is base64
  # expanded. Leave enough headroom for the runner's default native result
  # bound instead of advertising a content limit that can be rejected after
  # the read has already completed.
  @impl true
  def options, do: %{max_bytes: 47_000}

  @impl true
  def arguments(opts) do
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
         type: {:in, 1..opts.max_bytes},
         default: opts.max_bytes,
         doc: "Maximum bytes to read."
       ]
     ]}
  end

  @impl true
  def run(arguments, %{} = context, _opts \\ []) do
    path = arguments["path"]
    offset = arguments["offset"]
    limit = arguments["limit"]

    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, bytes} <- Alto.BoundedFile.range(resolved, offset, limit + 1) do
      content = binary_part(bytes, 0, min(byte_size(bytes), limit))

      encoded =
        if String.valid?(content),
          do: %{content: content},
          else: %{content_base64: Base.encode64(content), encoding: "base64"}

      {:ok,
       Map.merge(encoded, %{path: path, offset: offset, truncated: byte_size(bytes) > limit})}
    end
  end
end
