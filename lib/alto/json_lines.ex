defmodule Alto.JSONLines do
  @moduledoc "Framing durable JSON lines, independent of record semantics."
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
end
