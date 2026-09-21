defmodule Alto.Tools.FileChange do
  @moduledoc false

  alias Alto.BoundedFile
  alias Alto.Tools.AtomicWrite
  alias Alto.Tools.Path, as: SafePath

  def original(path, max_bytes, :write) do
    snapshot(max_bytes, :write, BoundedFile.fingerprint_snapshot(path, max_bytes))
  end

  def original(path, max_bytes, :edit) do
    snapshot(max_bytes, :edit, BoundedFile.snapshot(path, max_bytes))
  end

  defp snapshot(max_bytes, :edit, {:ok, %{content: nil}}),
    do: {:error, {:file_too_large, max_bytes}}

  defp snapshot(_max_bytes, _kind, {:ok, %{stat: stat} = value}),
    do: {:ok, Map.take(value, [:fingerprint, :bytes, :content]) |> Map.put(:mode, stat.mode)}

  defp snapshot(_max_bytes, :write, {:error, :enoent}), do: {:ok, :missing}
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
    kind = if operation == :write_file, do: :write, else: :edit

    with {:ok, resolved} <- SafePath.revalidate(path, expected, context.cwd),
         {:ok, mode} <- revalidate_original(original, resolved, max_bytes, kind, path) do
      case AtomicWrite.write(resolved, content, mode) do
        :ok -> {:ok, result}
        {:error, {:post_rename_sync_failed, reason}} -> {:unknown, reason}
        other -> other
      end
    end
  end

  def commit(_prepared, _context), do: {:error, :invalid_prepared_file_change}

  def preview(content, limit) do
    if byte_size(content) <= limit,
      do: %{content: content, truncated: false},
      else: %{content: Alto.Text.prefix(content, limit), truncated: true}
  end

  defp revalidate_original(expected, path, max_bytes, kind, display_path) do
    stale_path = if kind == :write, do: path, else: display_path

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
