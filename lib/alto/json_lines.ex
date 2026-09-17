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
    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, state}, fn {line, number}, {:ok, state} ->
      case apply_record.(state, line, number) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
