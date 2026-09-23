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

  defp split_lines(""), do: []

  defp split_lines(content) do
    content
    |> :binary.split("\n", [:global])
    |> add_newlines([])
  end

  defp add_newlines([last], acc) do
    case last do
      "" -> Enum.reverse(acc)
      _ -> Enum.reverse([last | acc])
    end
  end

  defp add_newlines([line | rest], acc), do: add_newlines(rest, [line <> "\n" | acc])

  defp records(before, updated) do
    before
    |> List.myers_difference(updated)
    |> Enum.reduce({[], 1, 1}, fn {kind, lines}, acc ->
      {tag, old_step, new_step} =
        case kind do
          :eq -> {:context, 1, 1}
          :del -> {:delete, 1, 0}
          :ins -> {:insert, 0, 1}
        end

      Enum.reduce(lines, acc, fn line, {records, old_line, new_line} ->
        {[{tag, line, old_line, new_line} | records], old_line + old_step, new_line + new_step}
      end)
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp hunk_ranges(records) do
    max_index = length(records) - 1

    records
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:context, _line, _old, _new}, _index} ->
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
    old_records = Enum.reject(records, &(elem(&1, 0) == :insert))
    new_records = Enum.reject(records, &(elem(&1, 0) == :delete))
    first = hd(records)

    old_start =
      case old_records do
        [] -> elem(first, 2) - 1
        [record | _] -> elem(record, 2)
      end

    new_start =
      case new_records do
        [] -> elem(first, 3) - 1
        [record | _] -> elem(record, 3)
      end

    [
      "@@ -",
      Integer.to_string(old_start),
      ",",
      Integer.to_string(length(old_records)),
      " +",
      Integer.to_string(new_start),
      ",",
      Integer.to_string(length(new_records)),
      " @@\n"
    ]
  end

  defp format_record({:context, line, _old, _new}), do: format_line(" ", line)
  defp format_record({:delete, line, _old, _new}), do: format_line("-", line)
  defp format_record({:insert, line, _old, _new}), do: format_line("+", line)

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
