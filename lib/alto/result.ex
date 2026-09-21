defmodule Alto.Result do
  @moduledoc "Composition of fallible operations returning `{:ok, value}` or `{:error, reason}`."

  @doc "Fold in enumeration order, stopping at the first error."
  @spec reduce(Enumerable.t(), term(), (term(), term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def reduce(items, initial, fun) do
    Enum.reduce_while(items, {:ok, initial}, fn item, {:ok, state} ->
      case fun.(item, state) do
        {:ok, _} = result -> {:cont, result}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "Map in enumeration order, stopping at the first error without invoking later operations."
  @spec traverse(Enumerable.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def traverse(items, fun) do
    with {:ok, values} <-
           reduce(items, [], fn item, values ->
             with {:ok, value} <- fun.(item), do: {:ok, [value | values]}
           end),
         do: {:ok, Enum.reverse(values)}
  end
end
