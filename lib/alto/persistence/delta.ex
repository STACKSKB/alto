defmodule Alto.Persistence.Delta do
  @moduledoc "Exact map/tuple changes for immutable durable terms."

  def hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
  def between(before, after_term), do: diff(before, after_term, [])

  def supported?(operations) when is_list(operations) and length(operations) <= 10_000 do
    Enum.all?(operations, fn
      {:put, path, _} ->
        is_list(path) and length(path) <= 64

      {:delete, path} ->
        is_list(path) and length(path) in 1..64

      {:resize, path, size} ->
        is_list(path) and length(path) <= 64 and is_integer(size) and size in 0..10_000

      _ ->
        false
    end)
  end

  def supported?(_), do: false

  def apply(term, operations) when is_list(operations) and length(operations) <= 10_000 do
    true = supported?(operations)
    {:ok, Enum.reduce(operations, term, &operation/2)}
  rescue
    _ -> {:error, :invalid_delta}
  end

  def apply(_, _), do: {:error, :invalid_delta}

  defp diff(same, same, _), do: []

  defp diff(before, after_term, path) when is_map(before) and is_map(after_term) do
    deleted =
      for key <- Map.keys(before), not Map.has_key?(after_term, key), do: {:delete, path ++ [key]}

    changed =
      Enum.flat_map(Map.to_list(after_term), fn {key, value} ->
        case Map.fetch(before, key) do
          {:ok, old} -> diff(old, value, path ++ [key])
          :error -> [{:put, path ++ [key], value}]
        end
      end)

    deleted ++ changed
  end

  defp diff(before, after_term, path) when is_tuple(before) and is_tuple(after_term) do
    size = tuple_size(after_term)
    resize = if tuple_size(before) == size, do: [], else: [{:resize, path, size}]

    changes =
      if size == 0,
        do: [],
        else:
          Enum.flat_map(0..(size - 1), fn i ->
            if i < tuple_size(before),
              do: diff(elem(before, i), elem(after_term, i), path ++ [i]),
              else: [{:put, path ++ [i], elem(after_term, i)}]
          end)

    resize ++ changes
  end

  defp diff(_before, after_term, path), do: [{:put, path, after_term}]

  defp operation({:put, path, value}, term), do: update(term, path, fn _ -> value end)

  defp operation({:resize, path, size}, term) when is_integer(size) and size in 0..10_000 do
    update(term, path, fn tuple ->
      true = is_tuple(tuple)

      tuple
      |> Tuple.to_list()
      |> Enum.take(size)
      |> then(&(&1 ++ List.duplicate(nil, max(size - tuple_size(tuple), 0))))
      |> List.to_tuple()
    end)
  end

  defp operation({:delete, path}, term) do
    {parent, [key]} = Enum.split(path, -1)

    update(term, parent, fn map ->
      true = is_map(map) and Map.has_key?(map, key)
      Map.delete(map, key)
    end)
  end

  defp update(term, [], fun), do: fun.(term)

  defp update(term, [key], fun) when is_map(term),
    do: Map.put(term, key, fun.(Map.get(term, key)))

  defp update(term, [key | rest], fun) when is_map(term),
    do: Map.put(term, key, update(Map.fetch!(term, key), rest, fun))

  defp update(term, [index | rest], fun) when is_tuple(term) and is_integer(index),
    do: put_elem(term, index, update(elem(term, index), rest, fun))
end
