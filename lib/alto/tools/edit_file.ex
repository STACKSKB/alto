defmodule Alto.Tools.EditFile do
  @moduledoc "Opt-in, atomic, workspace-confined exact-text edits."

  @behaviour Alto.Tool

  alias Alto.Tool.Context
  alias Alto.BoundedFile
  alias Alto.Tools.AtomicWrite
  alias Alto.Tools.Path, as: SafePath
  alias Alto.Tools.UnifiedDiff

  @max_file_bytes 1_000_000
  @max_replacement_bytes 256_000
  @max_edit_input_bytes @max_file_bytes + @max_replacement_bytes
  @max_edits 100
  @preview_bytes 4_096
  @patch_bytes 16_384
  @options_schema [
    max_file_bytes: [type: :pos_integer, default: @max_file_bytes],
    max_replacement_bytes: [type: :pos_integer, default: @max_replacement_bytes],
    max_edits: [type: :pos_integer, default: @max_edits],
    max_input_bytes: [type: :pos_integer, default: @max_edit_input_bytes],
    preview_bytes: [type: :non_neg_integer, default: @preview_bytes],
    patch_bytes: [type: :non_neg_integer, default: @patch_bytes]
  ]

  @impl true
  def name(_opts \\ []), do: :edit_file

  @impl true
  def schema(opts \\ []) when is_list(opts) do
    limits = validate_options!(opts)

    edit = %{
      type: "object",
      properties: %{
        old_text: %{type: "string", minLength: 1, description: "Exact text to replace."},
        new_text: %{type: "string", description: "Replacement text."},
        replace_all: %{
          type: "boolean",
          description: "Replace every exact match; defaults to false."
        }
      },
      required: ["old_text", "new_text"],
      additionalProperties: false
    }

    %{
      description:
        "Apply exact, non-overlapping text replacements to an existing UTF-8 workspace file. Every edit is matched against the same original snapshot; a match must be unique unless replace_all is true.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Workspace-relative or in-workspace absolute file path."
          },
          edits: %{
            type: "array",
            minItems: 1,
            maxItems: limits.max_edits,
            items:
              put_in(edit, [:properties, :new_text, :maxLength], limits.max_replacement_bytes),
            description: "Exact replacements, all matched against the original file snapshot."
          }
        },
        required: ["path", "edits"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def execution_mode(_opts \\ []), do: :exclusive

  @impl true
  def approval(_opts \\ []), do: :required

  @impl true
  def prepare(arguments, %Context{} = context, opts \\ []),
    do: prepare_edit(arguments, context, opts)

  @impl true
  def run_prepared(prepared, %Context{} = context, _opts \\ []) do
    with {:ok, resolved} <- revalidate_target(prepared, context),
         {:ok, stat, content} <-
           read_snapshot(
             resolved,
             prepared.limits.max_file_bytes
           ),
         :ok <- validate_fingerprint(prepared, stat, content),
         write_result <- AtomicWrite.write(resolved, prepared.updated, prepared.mode) do
      case write_result do
        :ok ->
          {:ok,
           %{
             path: prepared.path,
             replacements: prepared.replacements,
             bytes_before: byte_size(content),
             bytes_after: byte_size(prepared.updated),
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

  defp prepare_edit(arguments, %Context{} = context, opts)
       when is_map(arguments) and is_list(opts) do
    with {:ok, limits} <- validate_options(opts) do
      prepare_edit(arguments, context, limits)
    end
  end

  defp prepare_edit(arguments, %Context{} = context, limits) when is_map(arguments) do
    path = Map.get(arguments, "path")

    with {:ok, edits} <- edits(arguments),
         :ok <- validate_edits(edits, limits),
         {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, stat, content} <- read_snapshot(resolved, limits.max_file_bytes),
         :ok <- validate_utf8(content),
         {:ok, updated, replacements} <- apply_edits(content, edits, limits.max_file_bytes),
         :ok <- validate_size(byte_size(updated), limits.max_file_bytes) do
      prepared = %{
        operation: :edit_file,
        path: path,
        resolved: resolved,
        updated: updated,
        replacements: replacements,
        fingerprint: fingerprint(content),
        mode: stat.mode,
        patch: UnifiedDiff.render(path, content, updated, limits.patch_bytes),
        limits: limits
      }

      details = %{
        path: path,
        replacements: replacements,
        bytes_before: byte_size(content),
        bytes_after: byte_size(updated),
        preview: bounded(content: updated, limit: limits.preview_bytes),
        patch: prepared.patch
      }

      {:ok, prepared, details}
    end
  end

  defp prepare_edit(_arguments, _context, _opts), do: {:error, :edit_arguments_must_be_object}

  defp edits(%{"edits" => edits}) when is_list(edits) and edits != [], do: {:ok, edits}
  defp edits(_arguments), do: {:error, :edits_must_be_nonempty_list}

  defp validate_edits(edits, limits) when length(edits) > limits.max_edits,
    do: {:error, {:too_many_edits, limits.max_edits}}

  defp validate_edits(edits, limits) do
    with {:ok, input_bytes} <- validate_each_edit(edits, limits),
         true <-
           input_bytes <= limits.max_input_bytes or
             {:error, {:edit_input_too_large, limits.max_input_bytes}} do
      :ok
    end
  end

  defp validate_each_edit(edits, limits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0}, fn {edit, index}, {:ok, total} ->
      case validate_edit(edit, limits) do
        {:ok, bytes} -> {:cont, {:ok, total + bytes}}
        {:error, reason} -> {:halt, {:error, edit_error(index, reason, length(edits))}}
      end
    end)
  end

  defp validate_edit(edit, limits) when is_map(edit) do
    old_text = Map.get(edit, "old_text")
    new_text = Map.get(edit, "new_text")
    replace_all? = Map.get(edit, "replace_all", false)

    cond do
      not is_binary(old_text) or old_text == "" ->
        {:error, :old_text_must_be_nonempty}

      not String.valid?(old_text) ->
        {:error, :old_text_must_be_utf8}

      not is_binary(new_text) ->
        {:error, :new_text_must_be_string}

      not String.valid?(new_text) ->
        {:error, :new_text_must_be_utf8}

      byte_size(new_text) > limits.max_replacement_bytes ->
        {:error, {:replacement_too_large, limits.max_replacement_bytes}}

      replace_all? not in [true, false] ->
        {:error, :replace_all_must_be_boolean}

      true ->
        {:ok, byte_size(old_text) + byte_size(new_text)}
    end
  end

  defp validate_edit(_edit, _limits), do: {:error, :edit_must_be_object}

  defp edit_error(_index, reason, 1), do: reason
  defp edit_error(index, reason, _count), do: {:invalid_edit, index, reason}

  defp revalidate_target(%{operation: :edit_file, path: path, resolved: expected}, context) do
    SafePath.revalidate(path, expected, context.cwd)
  end

  defp revalidate_target(_prepared, _context), do: {:error, :invalid_prepared_edit}

  defp read_snapshot(path, max_file_bytes) do
    case BoundedFile.snapshot(path, max_file_bytes) do
      {:ok, %{content: nil}} -> {:error, {:file_too_large, max_file_bytes}}
      {:ok, %{stat: stat, content: content}} -> {:ok, stat, content}
      {:error, reason} -> {:error, reason}
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

  defp bounded(content: content, limit: limit) when byte_size(content) <= limit,
    do: %{content: content, truncated: false}

  defp bounded(content: content, limit: limit) do
    %{content: utf8_prefix(content, limit), truncated: true}
  end

  defp utf8_prefix(content, limit), do: Alto.Text.prefix(content, limit)

  defp validate_size(size, max_file_bytes) when size <= max_file_bytes, do: :ok
  defp validate_size(_size, max_file_bytes), do: {:error, {:file_too_large, max_file_bytes}}

  defp validate_utf8(content) do
    if String.valid?(content), do: :ok, else: {:error, :file_is_not_utf8}
  end

  defp apply_edits(content, edits, max_file_bytes) do
    with {:ok, replacements} <- collect_replacements(content, edits),
         :ok <- reject_overlaps(replacements),
         :ok <- validate_updated_size(content, replacements, max_file_bytes) do
      {:ok, replace_ranges(content, replacements), length(replacements)}
    end
  end

  defp collect_replacements(content, edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {edit, index}, {:ok, replacements} ->
      old_text = Map.fetch!(edit, "old_text")
      new_text = Map.fetch!(edit, "new_text")
      replace_all? = Map.get(edit, "replace_all", false)
      matches = :binary.matches(content, old_text)

      case select_matches(matches, replace_all?) do
        {:ok, selected} ->
          ranges =
            Enum.map(selected, fn {start, length} ->
              %{start: start, length: length, replacement: new_text, edit: index}
            end)

          {:cont, {:ok, ranges ++ replacements}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp select_matches([], _replace_all?), do: {:error, :text_not_found}

  defp select_matches(matches, false) when length(matches) > 1,
    do: {:error, {:ambiguous_match, length(matches)}}

  defp select_matches([match | _], false), do: {:ok, [match]}
  defp select_matches(matches, true), do: {:ok, matches}

  defp reject_overlaps(replacements) do
    replacements
    |> Enum.sort_by(&{&1.start, &1.length, &1.edit})
    |> Enum.reduce_while(nil, fn replacement, previous ->
      if previous != nil and replacement.start < previous.start + previous.length do
        {:halt, {:error, :overlapping_edits}}
      else
        {:cont, replacement}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      _last -> :ok
    end
  end

  defp validate_updated_size(content, replacements, max_file_bytes) do
    size =
      Enum.reduce(replacements, byte_size(content), fn replacement, total ->
        total - replacement.length + byte_size(replacement.replacement)
      end)

    validate_size(size, max_file_bytes)
  end

  defp replace_ranges(content, replacements) do
    {chunks, offset} =
      replacements
      |> Enum.sort_by(& &1.start)
      |> Enum.reduce({[], 0}, fn replacement, {chunks, offset} ->
        unchanged = binary_part(content, offset, replacement.start - offset)
        {[replacement.replacement, unchanged | chunks], replacement.start + replacement.length}
      end)

    tail = binary_part(content, offset, byte_size(content) - offset)
    [tail | chunks] |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp validate_options(opts),
    do: Alto.Tool.Options.validate(opts, @options_schema, :invalid_edit_options)

  defp validate_options!(opts), do: Map.new(NimbleOptions.validate!(opts, @options_schema))
end
