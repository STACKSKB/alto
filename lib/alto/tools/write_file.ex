defmodule Alto.Tools.WriteFile do
  @moduledoc "Opt-in, bounded, workspace-confined whole-file writes."

  @behaviour Alto.Tool

  alias Alto.Tool.Context
  alias Alto.BoundedFile
  alias Alto.Tools.AtomicWrite
  alias Alto.Tools.Path, as: SafePath

  @max_bytes 256_000
  @preview_bytes 4_096
  @options_schema [
    max_bytes: [type: :pos_integer, default: @max_bytes],
    preview_bytes: [type: :non_neg_integer, default: @preview_bytes],
    diff_bytes: [type: :non_neg_integer, default: 16_384]
  ]

  @impl true
  def name(_opts \\ []), do: :write_file

  @impl true
  def schema(opts \\ []) when is_list(opts) do
    limits = validate_options!(opts)

    %{
      description:
        "Create or replace a UTF-8 file inside the workspace. Parent directories must exist.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Workspace-relative or in-workspace absolute path."
          },
          content: %{type: "string", description: "Complete new file content."}
        },
        required: ["path", "content"],
        additionalProperties: false
      }
    }
    |> put_in([:parameters, :properties, :content, :maxLength], limits.max_bytes)
  end

  @impl true
  def execution_mode(_opts \\ []), do: :exclusive

  @impl true
  def approval(_opts \\ []), do: :required

  @impl true
  def prepare(arguments, %Context{} = context, opts \\ []),
    do: prepare_write(arguments, context, opts)

  @impl true
  def run_prepared(prepared, %Context{} = context, _opts \\ []) do
    with {:ok, resolved} <- revalidate_target(prepared, context),
         {:ok, mode} <- revalidate_original(prepared),
         write_result <- AtomicWrite.write(resolved, prepared.content, mode) do
      case write_result do
        :ok ->
          {:ok,
           %{
             path: prepared.path,
             bytes_written: byte_size(prepared.content),
             patch: Map.get(prepared, :patch)
           }}

        {:error, {:post_rename_sync_failed, reason}} ->
          {:unknown, reason}

        other ->
          other
      end
    end
  end

  @impl true
  def run(arguments, %Context{} = context, opts \\ []) do
    with {:ok, prepared, _details} <- prepare(arguments, context, opts) do
      run_prepared(prepared, context, opts)
    end
  end

  defp prepare_write(arguments, %Context{} = context, opts) when is_list(opts) do
    with {:ok, limits} <- validate_options(opts) do
      prepare_write(arguments, context, limits)
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
         {:ok, original} <- original_snapshot(resolved, limits.max_bytes) do
      prepared = %{
        operation: :write_file,
        path: path,
        resolved: resolved,
        content: content,
        original: if(is_map(original), do: Map.delete(original, :content), else: original),
        patch:
          Alto.Tools.UnifiedDiff.render(
            path,
            if(is_map(original), do: original.content, else: ""),
            content,
            limits.diff_bytes
          )
      }

      details = %{
        path: path,
        bytes_before: original_bytes(original),
        bytes_after: byte_size(content),
        preview: preview(content, limits.preview_bytes),
        patch: prepared.patch
      }

      {:ok, Map.put(prepared, :limits, limits), details}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp revalidate_target(%{operation: :write_file, path: path, resolved: expected}, context) do
    SafePath.revalidate(path, expected, context.cwd)
  end

  defp revalidate_target(_prepared, _context), do: {:error, :invalid_prepared_write}

  defp original_snapshot(path, max_bytes) do
    case BoundedFile.fingerprint_snapshot(path, max_bytes) do
      {:ok, %{stat: stat, content: content, fingerprint: fingerprint}} ->
        {:ok, %{fingerprint: fingerprint, mode: stat.mode, bytes: stat.size, content: content}}

      {:error, {:not_a_file, path}} ->
        {:error, {:not_a_file, path}}

      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_original(
         %{operation: :write_file, resolved: path, original: original} = prepared
       ) do
    limits = Map.get(prepared, :limits, %{max_bytes: @max_bytes})

    case {original, original_snapshot(path, limits.max_bytes)} do
      {:missing, {:ok, :missing}} ->
        {:ok, nil}

      {%{fingerprint: expected, mode: mode}, {:ok, %{fingerprint: expected, mode: mode}}} ->
        {:ok, mode}

      {_expected, {:ok, _actual}} ->
        {:error, {:stale_file, path}}

      {_expected, {:error, :enoent}} ->
        {:error, {:stale_file, path}}

      {_expected, {:error, reason}} ->
        {:error, reason}
    end
  end

  defp revalidate_original(_prepared), do: {:error, :invalid_prepared_write}

  defp original_bytes(:missing), do: 0
  defp original_bytes(%{bytes: bytes}), do: bytes

  defp preview(content, limit) when byte_size(content) <= limit,
    do: %{content: content, truncated: false}

  defp preview(content, limit) do
    %{content: Alto.Text.prefix(content, limit), truncated: true}
  end

  defp validate_options(opts),
    do: Alto.Tool.Options.validate(opts, @options_schema, :invalid_write_options)

  defp validate_options!(opts), do: Map.new(NimbleOptions.validate!(opts, @options_schema))
end
