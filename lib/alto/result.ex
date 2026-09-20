defmodule Alto.Result do
  @moduledoc "Composition of fallible operations returning `{:ok, value}` or `{:error, reason}`."

  @doc "Map in enumeration order, stopping at the first error without invoking later operations."
  @spec traverse(Enumerable.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def traverse(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, values} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
