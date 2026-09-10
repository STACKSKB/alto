defmodule Alto.Tools.WriteFile do
  @moduledoc "Opt-in, bounded, workspace-confined whole-file writes."

  @behaviour Alto.Tool

  alias Alto.Tool.Context
  alias Alto.Tools.AtomicWrite
  alias Alto.Tools.Path, as: SafePath

  @max_bytes 256_000
  @preview_bytes 4_096

  @impl true
  def name, do: :write_file

  @impl true
  def schema do
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
  end

  @impl true
  def execution_mode, do: :exclusive

  @impl true
  def approval, do: :required

  @impl true
  def prepare(arguments, %Context{} = context), do: prepare_write(arguments, context)

  @impl true
  def run_prepared(prepared, %Context{} = context) do
    with {:ok, resolved} <- revalidate_target(prepared, context),
         {:ok, mode} <- revalidate_original(prepared),
         :ok <- AtomicWrite.write(resolved, prepared.content, mode) do
      {:ok, %{path: prepared.path, bytes_written: byte_size(prepared.content)}}
    end
  end

  @impl true
  def run(arguments, %Context{} = context) do
    with {:ok, prepared, _details} <- prepare(arguments, context) do
      run_prepared(prepared, context)
    end
  end

  defp prepare_write(arguments, %Context{} = context) do
    path = Map.get(arguments, "path")
    content = Map.get(arguments, "content")

    with true <- is_binary(content) or {:error, :content_must_be_string},
         true <- String.valid?(content) or {:error, :content_is_not_utf8},
         true <- byte_size(content) <= @max_bytes or {:error, {:content_too_large, @max_bytes}},
         {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, original} <- original_snapshot(resolved) do
      prepared = %{
        operation: :write_file,
        path: path,
        resolved: resolved,
        content: content,
        original: original
      }

      details = %{
        path: path,
        bytes_before: original_bytes(original),
        bytes_after: byte_size(content),
        preview: preview(content)
      }

      {:ok, prepared, details}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp revalidate_target(%{operation: :write_file, path: path, resolved: expected}, context) do
    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         true <- resolved == expected or {:error, {:prepared_path_changed, path}} do
      {:ok, resolved}
    end
  end

  defp revalidate_target(_prepared, _context), do: {:error, :invalid_prepared_write}

  defp original_snapshot(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode} = stat} ->
        with {:ok, content} <- File.read(path) do
          {:ok, %{fingerprint: fingerprint(content), mode: mode, bytes: stat.size}}
        end

      {:ok, _stat} ->
        {:error, {:not_a_file, path}}

      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_original(%{operation: :write_file, resolved: path, original: original}) do
    case {original, original_snapshot(path)} do
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

  defp fingerprint(content), do: :crypto.hash(:sha256, content)

  defp original_bytes(:missing), do: 0
  defp original_bytes(%{bytes: bytes}), do: bytes

  defp preview(content) when byte_size(content) <= @preview_bytes,
    do: %{content: content, truncated: false}

  defp preview(content) do
    %{content: binary_part(content, 0, @preview_bytes), truncated: true}
  end
end
