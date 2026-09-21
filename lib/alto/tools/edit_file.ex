defmodule Alto.Tools.EditFile do
  @moduledoc "Opt-in, atomic, workspace-confined exact-text edits."

  use Alto.Tool, name: :edit_file, execution_mode: :exclusive, approval: :required

  alias Alto.Tool.Context
  alias Alto.Tools.FileChange
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
  def prepare(arguments, context, opts \\ [])

  def prepare(arguments, %Context{} = context, opts)
      when is_map(arguments) and is_list(opts) do
    with {:ok, limits} <- validate_options(opts),
         do: prepare_edit(arguments, context, limits)
  end

  def prepare(_arguments, _context, _opts), do: {:error, :edit_arguments_must_be_object}

  @impl true
  def run_prepared(prepared, %Context{} = context, _opts \\ []),
    do: FileChange.commit(prepared, context)

  @impl true
  def run(arguments, %Context{} = context, opts \\ []) do
    with {:ok, prepared, _details} <- prepare(arguments, context, opts) do
      run_prepared(prepared, context, opts)
    end
  end

  defp prepare_edit(arguments, %Context{} = context, limits) when is_map(arguments) do
    path = Map.get(arguments, "path")

    with {:ok, edits} <- edits(arguments),
         :ok <- validate_edits(edits, limits),
         {:ok, resolved} <- SafePath.resolve(path, context.cwd),
         {:ok, original} <- FileChange.original(resolved, limits.max_file_bytes, :edit),
         content = original.content,
         :ok <- validate_utf8(content),
         {:ok, updated, replacements} <- apply_edits(content, edits, limits.max_file_bytes),
         :ok <- validate_size(byte_size(updated), limits.max_file_bytes) do
      patch = UnifiedDiff.render(path, content, updated, limits.patch_bytes)

      result = %{
        path: path,
        replacements: replacements,
        bytes_before: original.bytes,
        bytes_after: byte_size(updated),
        patch: patch
      }

      prepared = %{
        operation: :edit_file,
        path: path,
        resolved: resolved,
        content: updated,
        original: Map.delete(original, :content),
        result: result,
        max_bytes: limits.max_file_bytes
      }

      {:ok, prepared,
       Map.put(result, :preview, FileChange.preview(updated, limits.preview_bytes))}
    end
  end

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
    with {:ok, groups} <-
           Alto.Result.traverse(edits, fn edit ->
             matches = :binary.matches(content, edit["old_text"])

             with {:ok, selected} <- select_matches(matches, Map.get(edit, "replace_all", false)),
                  do:
                    {:ok,
                     Enum.map(selected, fn {start, size} -> {start, size, edit["new_text"]} end)}
           end) do
      {:ok, groups |> List.flatten() |> Enum.sort_by(&elem(&1, 0))}
    end
  end

  defp select_matches([], _replace_all?), do: {:error, :text_not_found}

  defp select_matches(matches, false) when length(matches) > 1,
    do: {:error, {:ambiguous_match, length(matches)}}

  defp select_matches([match | _], false), do: {:ok, [match]}
  defp select_matches(matches, true), do: {:ok, matches}

  defp reject_overlaps(replacements) do
    Enum.reduce_while(replacements, 0, fn {start, size, _text}, previous_end ->
      if start < previous_end,
        do: {:halt, {:error, :overlapping_edits}},
        else: {:cont, start + size}
    end)
    |> case do
      {:error, _} = error -> error
      _end -> :ok
    end
  end

  defp validate_updated_size(content, replacements, max_file_bytes) do
    size =
      Enum.reduce(replacements, byte_size(content), fn {_start, size, text}, total ->
        total - size + byte_size(text)
      end)

    validate_size(size, max_file_bytes)
  end

  defp replace_ranges(content, replacements) do
    {chunks, offset} =
      Enum.reduce(replacements, {[], 0}, fn {start, size, text}, {chunks, offset} ->
        unchanged = binary_part(content, offset, start - offset)
        {[text, unchanged | chunks], start + size}
      end)

    tail = binary_part(content, offset, byte_size(content) - offset)
    [tail | chunks] |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp validate_options(opts),
    do: Alto.Tool.Options.validate(opts, @options_schema, :invalid_edit_options)

  defp validate_options!(opts), do: Map.new(NimbleOptions.validate!(opts, @options_schema))
end
