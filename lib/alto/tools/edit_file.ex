defmodule Alto.Tools.EditFile do
  @moduledoc "Opt-in, atomic, workspace-confined exact-text edits."

  @behaviour Alto.Tool

  alias Alto.Tool.Context
  alias Alto.Tools.AtomicWrite
  alias Alto.Tools.Path, as: SafePath

  @max_file_bytes 1_000_000
  @max_replacement_bytes 256_000
  @preview_bytes 4_096

  @impl true
  def name, do: :edit_file

  @impl true
  def schema do
    %{
      description:
        "Replace exact text in an existing UTF-8 workspace file. A match must be unique unless replace_all is true.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Workspace-relative or in-workspace absolute file path."
          },
          old_text: %{type: "string", minLength: 1, description: "Exact text to replace."},
          new_text: %{type: "string", description: "Replacement text."},
          replace_all: %{
            type: "boolean",
            description: "Replace every exact match; defaults to false."
          }
        },
        required: ["path", "old_text", "new_text"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def execution_mode, do: :exclusive

  @impl true
  def approval, do: :required

  @impl true
  def prepare(arguments, %Context{} = context), do: prepare_edit(arguments, context)

  @impl true
  def run_prepared(prepared, %Context{} = context) do
    with {:ok, resolved} <- revalidate_target(prepared, context),
         {:ok, stat, content} <- read_snapshot(resolved),
         :ok <- validate_fingerprint(prepared, stat, content),
         :ok <- AtomicWrite.write(resolved, prepared.updated, prepared.mode) do
      {:ok,
       %{
         path: prepared.path,
         replacements: prepared.replacements,
         bytes_before: byte_size(content),
         bytes_after: byte_size(prepared.updated)
       }}
    end
  end

  @impl true
  def run(arguments, %Context{} = context) do
    with {:ok, prepared, _details} <- prepare(arguments, context) do
      run_prepared(prepared, context)
    end
  end

  defp prepare_edit(arguments, %Context{} = context) do
    path = Map.get(arguments, "path")
    old_text = Map.get(arguments, "old_text")
    new_text = Map.get(arguments, "new_text")
    replace_all? = Map.get(arguments, "replace_all", false)

    with :ok <- validate_text(old_text, new_text, replace_all?),
         {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, stat, content} <- read_snapshot(resolved),
         :ok <- validate_size(stat.size),
         :ok <- validate_utf8(content),
         {:ok, updated, replacements} <- replace(content, old_text, new_text, replace_all?),
         :ok <- validate_size(byte_size(updated)) do
      prepared = %{
        operation: :edit_file,
        path: path,
        resolved: resolved,
        updated: updated,
        replacements: replacements,
        fingerprint: fingerprint(content),
        mode: stat.mode
      }

      details = %{
        path: path,
        replacements: replacements,
        bytes_before: byte_size(content),
        bytes_after: byte_size(updated),
        preview: preview(updated)
      }

      {:ok, prepared, details}
    end
  end

  defp revalidate_target(%{operation: :edit_file, path: path, resolved: expected}, context) do
    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         true <- resolved == expected or {:error, {:prepared_path_changed, path}} do
      {:ok, resolved}
    end
  end

  defp revalidate_target(_prepared, _context), do: {:error, :invalid_prepared_edit}

  defp read_snapshot(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular or {:error, {:not_a_file, path}},
         {:ok, content} <- File.read(path) do
      {:ok, stat, content}
    end
  end

  defp validate_fingerprint(prepared, stat, content) do
    cond do
      stat.mode != prepared.mode or fingerprint(content) != prepared.fingerprint ->
        {:error, {:stale_file, prepared.path}}

      true ->
        :ok
    end
  end

  defp fingerprint(content), do: :crypto.hash(:sha256, content)

  defp preview(content) when byte_size(content) <= @preview_bytes,
    do: %{content: content, truncated: false}

  defp preview(content) do
    %{content: binary_part(content, 0, @preview_bytes), truncated: true}
  end

  defp validate_text(old_text, new_text, replace_all?) do
    cond do
      not is_binary(old_text) or old_text == "" ->
        {:error, :old_text_must_be_nonempty}

      not is_binary(new_text) ->
        {:error, :new_text_must_be_string}

      byte_size(new_text) > @max_replacement_bytes ->
        {:error, {:replacement_too_large, @max_replacement_bytes}}

      replace_all? not in [true, false] ->
        {:error, :replace_all_must_be_boolean}

      true ->
        :ok
    end
  end

  defp validate_size(size) when size <= @max_file_bytes, do: :ok
  defp validate_size(_size), do: {:error, {:file_too_large, @max_file_bytes}}

  defp validate_utf8(content) do
    if String.valid?(content), do: :ok, else: {:error, :file_is_not_utf8}
  end

  defp replace(content, old_text, new_text, replace_all?) do
    matches = :binary.matches(content, old_text)
    count = length(matches)

    cond do
      count == 0 ->
        {:error, :text_not_found}

      count > 1 and not replace_all? ->
        {:error, {:ambiguous_match, count}}

      replace_all? ->
        {:ok, :binary.replace(content, old_text, new_text, [:global]), count}

      true ->
        {:ok, :binary.replace(content, old_text, new_text), 1}
    end
  end
end
