defmodule Alto.JSONLines do
  @moduledoc "Framing and folding durable JSON lines, independent of record semantics."
  def split(""), do: {[], false}

  def split(contents) do
    if :binary.last(contents) == ?\n do
      {String.split(contents, "\n", trim: true), false}
    else
      {complete, [tail]} = contents |> String.split("\n") |> Enum.split(-1)
      complete = Enum.reject(complete, &(&1 == ""))

      case JSON.decode(tail) do
        {:ok, _} -> {complete ++ [tail], true}
        {:error, _} -> {complete, true}
      end
    end
  end

  def join([]), do: ""
  def join(lines), do: Enum.join(lines, "\n") <> "\n"

  def fold(state, lines, apply_record) do
    Alto.Result.reduce(Enum.with_index(lines, 1), state, fn {line, number}, state ->
      apply_record.(state, line, number)
    end)
  end
end
