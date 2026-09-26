defmodule Alto.Tools.EditFile do
  @moduledoc "Opt-in, atomic, workspace-confined exact-text edits."

  use Alto.Tool, name: :edit_file, execution_mode: :exclusive, approval: :required

  alias Alto.Tool.Context
  alias Alto.Tools.FileChange

  @max_file_bytes 1_000_000
  @max_replacement_bytes 256_000
  @max_edit_input_bytes @max_file_bytes + @max_replacement_bytes
  @preview_bytes 4_096
  @patch_bytes 16_384
  @options_schema [
    max_file_bytes: [type: :pos_integer, default: @max_file_bytes],
    max_replacement_bytes: [type: :pos_integer, default: @max_replacement_bytes],
    max_edits: [type: :pos_integer, default: 100],
    max_input_bytes: [type: :pos_integer, default: @max_edit_input_bytes],
    preview_bytes: [type: :non_neg_integer, default: @preview_bytes],
    patch_bytes: [type: :non_neg_integer, default: @patch_bytes]
  ]

  @impl true
  def schema(opts \\ []) when is_list(opts) do
    limits = Alto.Tool.Options.validate!(opts, @options_schema)

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

    Alto.Tool.object_schema(
      "Apply exact, non-overlapping text replacements to an existing UTF-8 workspace file. Every edit is matched against the same original snapshot; a match must be unique unless replace_all is true.",
      %{
        path: %{
          type: "string",
          description: "Workspace-relative or in-workspace absolute file path."
        },
        edits: %{
          type: "array",
          minItems: 1,
          maxItems: limits.max_edits,
          items: put_in(edit, [:properties, :new_text, :maxLength], limits.max_replacement_bytes),
          description: "Exact replacements, all matched against the original file snapshot."
        }
      },
      ["path", "edits"]
    )
  end

  @impl true
  def prepare(arguments, context, opts \\ [])

  def prepare(arguments, %Context{} = context, opts)
      when is_map(arguments) and is_list(opts) do
    with {:ok, limits} <-
           Alto.Tool.Options.validate(opts, @options_schema, :invalid_edit_options),
         {:ok, edits} <- edits(arguments),
         :ok <- validate_edits(edits, limits) do
      FileChange.prepare(
        :edit_file,
        Map.get(arguments, "path"),
        context,
        {limits.max_file_bytes, limits.patch_bytes, limits.preview_bytes},
        fn content ->
          with :ok <- validate_utf8(content),
               {:ok, updated, replacements} <- apply_edits(content, edits, limits.max_file_bytes),
               do: {:ok, updated, %{replacements: replacements}}
        end
      )
    end
  end

  def prepare(_arguments, _context, _opts), do: {:error, :edit_arguments_must_be_object}

  @impl true
  def run(prepared, %Context{} = context, _opts \\ []),
    do: FileChange.commit(prepared, context)

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
         {:ok, chunks} <- replace_ranges(content, replacements),
         :ok <- validate_size(IO.iodata_length(chunks), max_file_bytes) do
      {:ok, IO.iodata_to_binary(chunks), length(replacements)}
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

  defp replace_ranges(content, replacements) do
    with {:ok, {chunks, offset}} <-
           Alto.Result.reduce(replacements, {[], 0}, fn {start, size, text}, {chunks, offset} ->
             if start < offset do
               {:error, :overlapping_edits}
             else
               unchanged = binary_part(content, offset, start - offset)
               {:ok, {[text, unchanged | chunks], start + size}}
             end
           end) do
      tail = binary_part(content, offset, byte_size(content) - offset)
      {:ok, Enum.reverse([tail | chunks])}
    end
  end
end
