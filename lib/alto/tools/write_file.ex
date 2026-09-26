defmodule Alto.Tools.WriteFile do
  @moduledoc "Opt-in, bounded, workspace-confined whole-file writes."

  use Alto.Tool,
    name: :write_file,
    execution_mode: :exclusive,
    approval: :required,
    arguments: true

  alias Alto.Tool.Arguments

  alias Alto.Tool.Context
  alias Alto.Tools.FileChange

  @preview_bytes 4_096
  @options_schema [
    max_bytes: [type: :pos_integer, default: 256_000],
    preview_bytes: [type: :non_neg_integer, default: @preview_bytes],
    diff_bytes: [type: :non_neg_integer, default: 16_384]
  ]

  @impl true
  def arguments(opts) do
    limits = Alto.Tool.Options.validate!(opts, @options_schema)

    {"Create or replace a UTF-8 file inside the workspace. Parent directories must exist.",
     [
       path: [type: :string, required: true],
       content: [type: Arguments.text(0, limits.max_bytes), required: true]
     ]}
  end

  @impl true
  def prepare(arguments, %Context{} = context, opts \\ []) when is_list(opts) do
    with {:ok, limits} <-
           Alto.Tool.Options.validate(opts, @options_schema, :invalid_write_options),
         content = arguments["content"] do
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
