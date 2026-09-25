defmodule Alto.Tools.WriteFile do
  @moduledoc "Opt-in, bounded, workspace-confined whole-file writes."

  use Alto.Tool, name: :write_file, execution_mode: :exclusive, approval: :required

  alias Alto.Tool.Context
  alias Alto.Tools.FileChange
  alias Alto.Tools.Path, as: SafePath

  @preview_bytes 4_096
  @options_schema [
    max_bytes: [type: :pos_integer, default: 256_000],
    preview_bytes: [type: :non_neg_integer, default: @preview_bytes],
    diff_bytes: [type: :non_neg_integer, default: 16_384]
  ]

  @impl true
  def schema(opts \\ []) when is_list(opts) do
    limits = validate_options!(opts)

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
    with {:ok, limits} <- validate_options(opts),
         do: prepare_write(arguments, context, limits)
  end

  @impl true
  def run_prepared(prepared, %Context{} = context, _opts \\ []),
    do: FileChange.commit(prepared, context)

  @impl true
  def run(arguments, %Context{} = context, opts \\ []) do
    with {:ok, prepared, _details} <- prepare(arguments, context, opts) do
      run_prepared(prepared, context, opts)
    end
  end

  defp prepare_write(arguments, %Context{} = context, limits) when is_map(limits) do
    path = Map.get(arguments, "path")
    content = Map.get(arguments, "content")

    with true <- is_binary(content) or {:error, :content_must_be_string},
         true <- String.valid?(content) or {:error, :content_is_not_utf8},
         true <-
           byte_size(content) <= limits.max_bytes or
             {:error, {:content_too_large, limits.max_bytes}},
         {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, original} <- FileChange.original(resolved, limits.max_bytes, :write) do
      patch =
        Alto.Tools.UnifiedDiff.render(
          path,
          if(is_map(original), do: original.content, else: ""),
          content,
          limits.diff_bytes
        )

      result = %{path: path, bytes_written: byte_size(content), patch: patch}

      prepared = %{
        operation: :write_file,
        path: path,
        resolved: resolved,
        content: content,
        original: if(is_map(original), do: Map.delete(original, :content), else: original),
        result: result,
        max_bytes: limits.max_bytes
      }

      details = %{
        path: path,
        bytes_before: original_bytes(original),
        bytes_after: byte_size(content),
        preview: FileChange.preview(content, limits.preview_bytes),
        patch: patch
      }

      {:ok, prepared, details}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp original_bytes(:missing), do: 0
  defp original_bytes(%{bytes: bytes}), do: bytes

  defp validate_options(opts),
    do: Alto.Tool.Options.validate(opts, @options_schema, :invalid_write_options)

  defp validate_options!(opts), do: Map.new(NimbleOptions.validate!(opts, @options_schema))
end
