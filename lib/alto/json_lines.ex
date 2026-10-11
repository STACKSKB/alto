defmodule Alto.JSONLines do
  @moduledoc "Framing and folding durable JSON lines, independent of record semantics."
  def split(""), do: {[], false}

  def split(contents) do
    lines = String.split(contents, "\n", trim: true)
    torn? = :binary.last(contents) != ?\n

    if torn? and match?({:error, _}, JSON.decode(List.last(lines))),
      do: {Enum.drop(lines, -1), true},
      else: {lines, torn?}
  end

  def join([]), do: ""
  def join(lines), do: Enum.join(lines, "\n") <> "\n"

  def fold(state, lines, apply_record) do
    Alto.Result.reduce(Enum.with_index(lines, 1), state, fn {line, number}, state ->
      apply_record.(state, line, number)
    end)
  end
end
