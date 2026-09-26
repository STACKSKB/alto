defmodule Alto.Tools.WriteFile do
  @moduledoc "Opt-in, bounded, workspace-confined whole-file writes."

  use Alto.Tool, name: :write_file, execution_mode: :exclusive, approval: :required

  alias Alto.Tool.Context
  alias Alto.Tools.FileChange

  @preview_bytes 4_096
  @options_schema [
    max_bytes: [type: :pos_integer, default: 256_000],
    preview_bytes: [type: :non_neg_integer, default: @preview_bytes],
    diff_bytes: [type: :non_neg_integer, default: 16_384]
  ]

  @impl true
  def schema(opts \\ []) when is_list(opts) do
    limits = Alto.Tool.Options.validate!(opts, @options_schema)

    Alto.Tool.object_schema(
      "Create or replace a UTF-8 file inside the workspace. Parent directories must exist.",
      %{
        path: %{
          type: "string",
          description: "Workspace-relative or in-workspace absolute path."
        },
        content: %{type: "string", description: "Complete new file content."}
      },
      ["path", "content"]
    )
    |> put_in([:parameters, :properties, :content, :maxLength], limits.max_bytes)
  end

  @impl true
  def prepare(arguments, %Context{} = context, opts \\ []) when is_list(opts) do
    with {:ok, limits} <-
           Alto.Tool.Options.validate(opts, @options_schema, :invalid_write_options),
         content = Map.get(arguments, "content"),
         true <- is_binary(content) or {:error, :content_must_be_string},
         true <- String.valid?(content) or {:error, :content_is_not_utf8},
         true <-
           byte_size(content) <= limits.max_bytes or
             {:error, {:content_too_large, limits.max_bytes}} do
      FileChange.prepare(
        :write_file,
        Map.get(arguments, "path"),
        context,
        {limits.max_bytes, limits.diff_bytes, limits.preview_bytes},
        fn _original -> {:ok, content, %{}} end
      )
    end
  end

  @impl true
  def run(prepared, %Context{} = context, _opts \\ []),
    do: FileChange.commit(prepared, context)
end
