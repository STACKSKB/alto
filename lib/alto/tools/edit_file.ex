defmodule Alto.Tools.EditFile do
  @moduledoc "Opt-in, atomic, workspace-confined exact-text edits."

  use Alto.Tool,
    name: :edit_file,
    execution_mode: :exclusive,
    approval: :required,
    arguments: true

  alias Alto.Tool.Arguments

  alias Alto.Tools.FileChange

  @max_file_bytes 1_000_000
  @max_replacement_bytes 256_000
  @max_edit_input_bytes @max_file_bytes + @max_replacement_bytes
  @preview_bytes 4_096
  @patch_bytes 16_384
  @impl true
  def options,
    do: %{
      max_file_bytes: @max_file_bytes,
      max_replacement_bytes: @max_replacement_bytes,
      max_edits: 100,
      max_input_bytes: @max_edit_input_bytes,
      preview_bytes: @preview_bytes,
      patch_bytes: @patch_bytes
    }

  @impl true
  def arguments(opts) do
    {"Apply exact, non-overlapping text replacements to an existing UTF-8 workspace file. Every edit is matched against the same original snapshot. Ambiguous matches report the 1-based edit index and up to eight matching source lines; add longer unique context, or use replace_all only when every occurrence is intended.",
     [
       path: [type: :string, required: true],
       edits: [
         type:
           Arguments.list(
             Arguments.object(
               old_text: [type: Arguments.text(1, :infinity), required: true],
               new_text: [type: Arguments.text(0, opts.max_replacement_bytes), required: true],
               replace_all: [
                 type: :boolean,
                 default: false,
                 doc: "Set true only when every occurrence of old_text should be replaced."
               ]
             ),
             1,
             opts.max_edits
           ),
         required: true
       ]
     ]}
  end

  @impl true
  def prepare(arguments, context, opts \\ [])

  def prepare(arguments, %{} = context, opts)
      when is_map(arguments) do
    with edits = arguments["edits"],
         true <-
           Enum.sum(Enum.map(edits, &(byte_size(&1["old_text"]) + byte_size(&1["new_text"])))) <=
             opts.max_input_bytes or
             {:error, {:edit_input_too_large, opts.max_input_bytes}} do
      FileChange.prepare(
        :edit_file,
        Map.get(arguments, "path"),
        context,
        {opts.max_file_bytes, opts.patch_bytes, opts.preview_bytes},
        fn content ->
          with :ok <- validate_utf8(content),
               {:ok, updated, replacements} <- apply_edits(content, edits, opts.max_file_bytes),
               do: {:ok, updated, %{replacements: replacements}}
        end
      )
    end
  end

  def prepare(_arguments, _context, _opts), do: {:error, :edit_arguments_must_be_object}

  @impl true
  def run(prepared, %{} = context, _opts \\ []),
    do: FileChange.commit(prepared, context)

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
           edits
           |> Enum.with_index(1)
           |> Alto.Result.traverse(fn {edit, edit_index} ->
             matches = :binary.matches(content, edit["old_text"])

             with {:ok, selected} <-
                    select_matches(
                      content,
                      matches,
                      Map.get(edit, "replace_all", false),
                      edit_index
                    ),
                  do:
                    {:ok,
                     Enum.map(selected, fn {start, size} -> {start, size, edit["new_text"]} end)}
           end) do
      {:ok, groups |> List.flatten() |> Enum.sort_by(&elem(&1, 0))}
    end
  end

  defp select_matches(_content, [], _replace_all?, _edit_index),
    do: {:error, :text_not_found}

  defp select_matches(content, matches, false, edit_index) when length(matches) > 1 do
    locations = Enum.take(matches, 9)
    visible = Enum.take(locations, 8)
    truncated? = length(locations) > 8

    info = %{
      edit_index: edit_index,
      match_lines: Enum.map(visible, fn {offset, _size} -> line_at(content, offset) end),
      locations_truncated: truncated?,
      hint:
        "Include more surrounding text to identify one occurrence, or set replace_all=true only if every occurrence is intended."
    }

    {:error, {:ambiguous_match, length(matches), info}}
  end

  defp select_matches(_content, [match | _], false, _edit_index), do: {:ok, [match]}
  defp select_matches(_content, matches, true, _edit_index), do: {:ok, matches}

  defp line_at(content, offset) do
    content
    |> binary_part(0, offset)
    |> then(&:binary.matches(&1, "\n"))
    |> length()
    |> Kernel.+(1)
  end

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
