defmodule Alto.Tools.UnifiedDiff do
  @moduledoc false

  @context_lines 3

  @doc "Return a bounded patch, or nil when disabled or the original content was not retained."
  @spec render(binary(), binary() | nil, binary(), non_neg_integer()) ::
          %{content: binary(), truncated: boolean()} | nil
  def render(_path, nil, _updated, _limit), do: nil
  def render(_path, _before, _updated, 0), do: nil

  def render(path, before, updated, limit)
      when is_binary(path) and is_binary(before) and is_binary(updated) and is_integer(limit) and
             limit > 0 do
    records = records(split_lines(before), split_lines(updated))
    ranges = hunk_ranges(records)

    chunks =
      ["--- a/", path, "\n", "+++ b/", path, "\n"] ++
        Enum.flat_map(ranges, fn {first, last} ->
          hunk = Enum.slice(records, first..last)
          [hunk_header(hunk) | Enum.map(hunk, &format_record/1)]
        end)

    {content, truncated?} = take_chunks(chunks, limit, [])
    %{content: content, truncated: truncated?}
  end

  defp split_lines(content), do: Regex.scan(~r/[^\n]*\n|[^\n]+$/, content) |> List.flatten()

  defp records(before, updated) do
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

  defp hunk_ranges(records) do
    max_index = length(records) - 1

    records
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:eq, _line, _old, _new}, _index} ->
        []

      {_record, index} ->
        [{max(0, index - @context_lines), min(max_index, index + @context_lines)}]
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

  defp hunk_header(records) do
    {_, _, old, new} = hd(records)
    old_count = Enum.count(records, &(elem(&1, 0) != :ins))
    new_count = Enum.count(records, &(elem(&1, 0) != :del))
    old = if old_count == 0, do: old - 1, else: old
    new = if new_count == 0, do: new - 1, else: new
    "@@ -#{old},#{old_count} +#{new},#{new_count} @@\n"
  end

  defp format_record({:eq, line, _old, _new}), do: format_line(" ", line)
  defp format_record({:del, line, _old, _new}), do: format_line("-", line)
  defp format_record({:ins, line, _old, _new}), do: format_line("+", line)

  defp format_line(prefix, line) do
    if String.ends_with?(line, "\n"),
      do: [prefix, line],
      else: [prefix, line, "\n\\ No newline at end of file\n"]
  end

  defp take_chunks([], _remaining, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), false}

  defp take_chunks(_chunks, 0, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), true}

  defp take_chunks([chunk | rest], remaining, acc) when is_list(chunk),
    do: take_chunks(chunk ++ rest, remaining, acc)

  defp take_chunks([chunk | rest], remaining, acc) do
    size = byte_size(chunk)

    if size <= remaining do
      take_chunks(rest, remaining - size, [chunk | acc])
    else
      prefix = Alto.Text.prefix(chunk, remaining)
      {Enum.reverse([prefix | acc]) |> IO.iodata_to_binary(), true}
    end
  end
end
