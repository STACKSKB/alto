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
  @impl true
  def options,
    do: %{
      max_bytes: 256_000,
      preview_bytes: @preview_bytes,
      diff_bytes: 16_384
    }

  @impl true
  def arguments(opts) do
    {"Create or replace a UTF-8 file inside the workspace. Parent directories must exist.",
     [
       path: [type: :string, required: true],
       content: [type: Arguments.text(0, opts.max_bytes), required: true]
     ]}
  end

  @impl true
  def prepare(arguments, %Context{} = context, limits) do
    FileChange.prepare(
      :write_file,
      Map.get(arguments, "path"),
      context,
      {limits.max_bytes, limits.diff_bytes, limits.preview_bytes},
      fn _original -> {:ok, arguments["content"], %{}} end
    )
  end

  @impl true
  def run(prepared, %Context{} = context, _opts \\ []),
    do: FileChange.commit(prepared, context)
end
