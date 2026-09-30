defmodule Alto.Contrib.Tools.UnifiedDiffDisjointTest do
  use ExUnit.Case, async: true

  alias Alto.Contrib.Tools.UnifiedDiff

  test "large disjoint line sets exactly match the Myers reference output" do
    before_cases = [
      Enum.map(1..80, &"old #{&1}\n"),
      Enum.map(1..72, &"old #{&1}\n") ++ ["last old"],
      Enum.map(1..90, &"old #{&1}\n")
    ]

    updated_cases = [
      Enum.map(1..65, &"new #{&1}\n"),
      Enum.map(1..100, &"new #{&1}\n") ++ ["last new"],
      Enum.map(1..64, &"replacement #{&1}\n")
    ]

    for before_lines <- before_cases,
        updated_lines <- updated_cases,
        limit <- [1, 80, 10_000] do
      before = IO.iodata_to_binary(before_lines)
      updated = IO.iodata_to_binary(updated_lines)

      assert UnifiedDiff.render("notes.txt", before, updated, limit) ==
               reference_render("notes.txt", before, updated, limit)
    end
  end

  test "empty sides, repeated lines, and shared-line fallbacks preserve output" do
    long = String.duplicate("old\n", 70)

    cases = [
      {"", long},
      {long, ""},
      {long, String.duplicate("new\n", 70)},
      {long, long},
      {long, "new\n" <> long},
      {long <> "shared", String.duplicate("new\n", 70) <> "shared"},
      {String.duplicate("a\n", 31), String.duplicate("b\n", 32)},
      {String.duplicate("a\n", 32), String.duplicate("b\n", 32)}
    ]

    for {before, updated} <- cases, limit <- [1, 80, 10_000] do
      assert UnifiedDiff.render("notes.txt", before, updated, limit) ==
               reference_render("notes.txt", before, updated, limit)
    end
  end

  # Kept as the pre-optimization implementation so this test catches changes in
  # ordering, line numbering, hunk boundaries, headers, and missing final newlines.
  defp reference_render(path, before, updated, limit) do
    records = reference_records(split_lines(before), split_lines(updated))
    ranges = reference_hunk_ranges(records)

    chunks =
      ["--- a/", path, "\n", "+++ b/", path, "\n"] ++
        Enum.flat_map(ranges, fn {first, last} ->
          hunk = Enum.slice(records, first..last)
          [reference_hunk_header(hunk) | Enum.map(hunk, &reference_format_record/1)]
        end)

    Alto.Text.preview(chunks, limit)
  end

  defp split_lines(content), do: Regex.scan(~r/[^\n]*\n|[^\n]+$/, content) |> List.flatten()

  defp reference_records(before, updated) do
    {records, _} =
      before
      |> List.myers_difference(updated)
      |> Enum.flat_map(fn {tag, lines} -> Enum.map(lines, &{tag, &1}) end)
      |> Enum.map_reduce({1, 1}, fn {tag, line}, {old, new} ->
        {{tag, line, old, new},
         {old + if(tag == :ins, do: 0, else: 1), new + if(tag == :del, do: 0, else: 1)}}
      end)

    records
  end

  defp reference_hunk_ranges(records) do
    max_index = length(records) - 1

    records
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:eq, _line, _old, _new}, _index} -> []
      {_record, index} -> [{max(0, index - 3), min(max_index, index + 3)}]
    end)
    |> Enum.reduce([], fn
      range, [] ->
        [range]

      {first, last}, [{previous_first, previous_last} | rest]
      when first <= previous_last + 1 ->
        [{previous_first, max(previous_last, last)} | rest]

      range, ranges ->
        [range | ranges]
    end)
    |> Enum.reverse()
  end

  defp reference_hunk_header(records) do
    {_, _, old, new} = hd(records)
    old_count = Enum.count(records, &(elem(&1, 0) != :ins))
    new_count = Enum.count(records, &(elem(&1, 0) != :del))
    old = if old_count == 0, do: old - 1, else: old
    new = if new_count == 0, do: new - 1, else: new
    "@@ -#{old},#{old_count} +#{new},#{new_count} @@\n"
  end

  defp reference_format_record({:eq, line, _old, _new}), do: reference_format_line(" ", line)
  defp reference_format_record({:del, line, _old, _new}), do: reference_format_line("-", line)
  defp reference_format_record({:ins, line, _old, _new}), do: reference_format_line("+", line)

  defp reference_format_line(prefix, line) do
    if String.ends_with?(line, "\n"),
      do: [prefix, line],
      else: [prefix, line, "\n\\ No newline at end of file\n"]
  end
end
