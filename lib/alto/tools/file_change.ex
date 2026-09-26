defmodule Alto.Tools.FileChange do
  @moduledoc false

  alias Alto.BoundedFile
  alias Alto.AtomicFile
  alias Alto.Tools.Path, as: SafePath

  def prepare(operation, path, context, {max_bytes, patch_bytes, preview_bytes}, transform) do
    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, original} <- original(resolved, max_bytes, operation),
         before = if(original == :missing, do: "", else: original.content),
         {:ok, content, fields} <- transform.(before) do
      result =
        Map.merge(fields, %{
          path: path,
          bytes_before: if(original == :missing, do: 0, else: original.bytes),
          bytes_after: byte_size(content),
          patch: Alto.Tools.UnifiedDiff.render(path, before, content, patch_bytes)
        })

      prepared = %{
        operation: operation,
        path: path,
        resolved: resolved,
        content: content,
        original: if(is_map(original), do: Map.delete(original, :content), else: original),
        result: result,
        max_bytes: max_bytes
      }

      {:ok, prepared, Map.put(result, :preview, preview(content, preview_bytes))}
    end
  end

  defp original(path, max_bytes, :write_file) do
    snapshot(max_bytes, :write_file, BoundedFile.fingerprint_snapshot(path, max_bytes))
  end

  defp original(path, max_bytes, :edit_file) do
    snapshot(max_bytes, :edit_file, BoundedFile.snapshot(path, max_bytes))
  end

  defp snapshot(max_bytes, :edit_file, {:ok, %{content: nil}}),
    do: {:error, {:file_too_large, max_bytes}}

  defp snapshot(_max_bytes, _kind, {:ok, %{stat: stat} = value}),
    do: {:ok, Map.take(value, [:fingerprint, :bytes, :content]) |> Map.put(:mode, stat.mode)}

  defp snapshot(_max_bytes, :write_file, {:error, :enoent}), do: {:ok, :missing}
  defp snapshot(_max_bytes, _kind, error), do: error

  def commit(
        %{
          operation: operation,
          path: path,
          resolved: expected,
          original: original,
          content: content,
          max_bytes: max_bytes,
          result: result
        },
        context
      )
      when operation in [:write_file, :edit_file] do
    with {:ok, resolved} <- SafePath.revalidate(path, expected, context.cwd),
         {:ok, mode} <- revalidate_original(original, resolved, max_bytes, operation, path) do
      case AtomicFile.write(resolved, content, mode: mode) do
        :ok -> {:ok, result}
        {:error, {:post_rename_sync_failed, reason}} -> {:unknown, reason}
        other -> other
      end
    end
  end

  def commit(_prepared, _context), do: {:error, :invalid_prepared_file_change}

  defp preview(content, limit) do
    if byte_size(content) <= limit,
      do: %{content: content, truncated: false},
      else: %{content: Alto.Text.prefix(content, limit), truncated: true}
  end

  defp revalidate_original(expected, path, max_bytes, kind, display_path) do
    stale_path = if kind == :write_file, do: path, else: display_path

    case {expected, original(path, max_bytes, kind)} do
      {:missing, {:ok, :missing}} ->
        {:ok, nil}

      {%{fingerprint: fingerprint, mode: mode}, {:ok, %{fingerprint: fingerprint, mode: mode}}} ->
        {:ok, mode}

      {_expected, {:ok, _actual}} ->
        {:error, {:stale_file, stale_path}}

      {_expected, {:error, :enoent}} ->
        {:error, {:stale_file, stale_path}}

      {_expected, error} ->
        error
    end
  end
end
