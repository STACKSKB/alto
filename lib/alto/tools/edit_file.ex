defmodule Alto.Tools.EditFile do
  @moduledoc "Opt-in, atomic, workspace-confined exact-text edits."

  @behaviour Alto.Tool

  alias Alto.Tool.Context
  alias Alto.Tools.AtomicWrite
  alias Alto.Tools.Path, as: SafePath
  alias Alto.Tools.UnifiedDiff

  @max_file_bytes 1_000_000
  @max_replacement_bytes 256_000
  # This retains every feasible legacy request: an old_text that can fill the
  # largest accepted file plus the largest accepted replacement.
  @max_edit_input_bytes @max_file_bytes + @max_replacement_bytes
  @max_edits 100
  @preview_bytes 4_096
  @patch_bytes 16_384

  @impl true
  def name, do: :edit_file

  @impl true
  def schema do
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
            maxItems: @max_edits,
            items: edit,
            description: "Exact replacements, all matched against the original file snapshot."
          },
          old_text: edit.properties.old_text,
          new_text: edit.properties.new_text,
          replace_all: edit.properties.replace_all
        },
        required: ["path"],
        oneOf: [
          %{required: ["edits"]},
          %{required: ["old_text", "new_text"]}
        ],
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
         bytes_after: byte_size(prepared.updated),
         patch: Map.get(prepared, :patch)
       }}
    end
  end

  @impl true
  def run(arguments, %Context{} = context) do
    with {:ok, prepared, _details} <- prepare(arguments, context) do
      run_prepared(prepared, context)
    end
  end

  defp prepare_edit(arguments, %Context{} = context) when is_map(arguments) do
    path = Map.get(arguments, "path")

    with {:ok, edits} <- normalize_edits(arguments),
         :ok <- validate_edits(edits),
         {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, stat, content} <- read_snapshot(resolved),
         :ok <- validate_utf8(content),
         {:ok, updated, replacements} <- apply_edits(content, edits),
         :ok <- validate_size(byte_size(updated)) do
      prepared = %{
        operation: :edit_file,
        path: path,
        resolved: resolved,
        updated: updated,
        replacements: replacements,
        fingerprint: fingerprint(content),
        mode: stat.mode,
        patch: UnifiedDiff.render(path, content, updated, @patch_bytes)
      }

      details = %{
        path: path,
        replacements: replacements,
        bytes_before: byte_size(content),
        bytes_after: byte_size(updated),
        preview: bounded(content: updated, limit: @preview_bytes),
        patch: prepared.patch
      }

      {:ok, prepared, details}
    end
  end

  defp prepare_edit(_arguments, _context), do: {:error, :edit_arguments_must_be_object}

  defp normalize_edits(arguments) do
    has_edits? = Map.has_key?(arguments, "edits")

    has_legacy? =
      Enum.any?(["old_text", "new_text", "replace_all"], &Map.has_key?(arguments, &1))

    cond do
      has_edits? and has_legacy? ->
        {:error, :mixed_edit_arguments}

      has_edits? ->
        case Map.fetch!(arguments, "edits") do
          edits when is_list(edits) and edits != [] -> {:ok, edits}
          _ -> {:error, :edits_must_be_nonempty_list}
        end

      true ->
        {:ok,
         [
           %{
             "old_text" => Map.get(arguments, "old_text"),
             "new_text" => Map.get(arguments, "new_text"),
             "replace_all" => Map.get(arguments, "replace_all", false)
           }
         ]}
    end
  end

  defp validate_edits(edits) when length(edits) > @max_edits,
    do: {:error, {:too_many_edits, @max_edits}}

  defp validate_edits(edits) do
    with {:ok, input_bytes} <- validate_each_edit(edits),
         true <-
           input_bytes <= @max_edit_input_bytes or
             {:error, {:edit_input_too_large, @max_edit_input_bytes}} do
      :ok
    end
  end

  defp validate_each_edit(edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0}, fn {edit, index}, {:ok, total} ->
      case validate_edit(edit) do
        {:ok, bytes} -> {:cont, {:ok, total + bytes}}
        {:error, reason} -> {:halt, {:error, edit_error(index, reason, length(edits))}}
      end
    end)
  end

  defp validate_edit(edit) when is_map(edit) do
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

      byte_size(new_text) > @max_replacement_bytes ->
        {:error, {:replacement_too_large, @max_replacement_bytes}}

      replace_all? not in [true, false] ->
        {:error, :replace_all_must_be_boolean}

      true ->
        {:ok, byte_size(old_text) + byte_size(new_text)}
    end
  end

  defp validate_edit(_edit), do: {:error, :edit_must_be_object}

  defp edit_error(_index, reason, 1), do: reason
  defp edit_error(index, reason, _count), do: {:invalid_edit, index, reason}

  defp revalidate_target(%{operation: :edit_file, path: path, resolved: expected}, context) do
    with {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         true <- resolved == expected or {:error, {:prepared_path_changed, path}} do
      {:ok, resolved}
    end
  end

  defp revalidate_target(_prepared, _context), do: {:error, :invalid_prepared_edit}

  defp read_snapshot(path) do
    case :file.open(String.to_charlist(path), [:read, :binary]) do
      {:ok, file} ->
        try do
          with {:ok, info} <- :file.read_file_info(file),
               stat = File.Stat.from_record(info),
               true <- stat.type == :regular or {:error, {:not_a_file, path}},
               {:ok, content} <- read_bounded(file, @max_file_bytes + 1),
               :ok <- validate_size(byte_size(content)) do
            {:ok, stat, content}
          end
        after
          :file.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_bounded(file, limit), do: read_bounded(file, limit, [])

  defp read_bounded(_file, 0, chunks),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_bounded(file, remaining, chunks) do
    case :file.read(file, remaining) do
      {:ok, ""} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      {:ok, chunk} -> read_bounded(file, remaining - byte_size(chunk), [chunk | chunks])
      :eof -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
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

  defp validate_size(size) when size <= @max_file_bytes, do: :ok
  defp validate_size(_size), do: {:error, {:file_too_large, @max_file_bytes}}

  defp validate_utf8(content) do
    if String.valid?(content), do: :ok, else: {:error, :file_is_not_utf8}
  end

  defp apply_edits(content, edits) do
    with {:ok, replacements} <- collect_replacements(content, edits),
         :ok <- reject_overlaps(replacements),
         :ok <- validate_updated_size(content, replacements) do
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

  defp validate_updated_size(content, replacements) do
    size =
      Enum.reduce(replacements, byte_size(content), fn replacement, total ->
        total - replacement.length + byte_size(replacement.replacement)
      end)

    validate_size(size)
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
end
