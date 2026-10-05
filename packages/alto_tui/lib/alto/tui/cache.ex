defmodule Alto.TUI.Cache do
  @moduledoc "One byte-budgeted, owner-aware working set for derived UI content."
  @key {__MODULE__, :items}
  @default_bytes 16_000_000

  def configure(bytes) when is_integer(bytes) and bytes >= 0 do
    if Process.get({__MODULE__, :limit}) != bytes do
      Process.put({__MODULE__, :limit}, bytes)
      Process.put(@key, trim_bytes(stats(), bytes))
    end

    :ok
  end

  def owner(id), do: Process.put({__MODULE__, :owner}, id)
  def stats, do: Process.get(@key, %{items: %{}, order: [], bytes: 0})
  def clear, do: Process.delete(@key)

  @doc "Peek at the most recently used item in a namespace within the shared byte budget."
  def latest(namespace) do
    cache = stats()

    Enum.find_value(cache.order, fn
      {^namespace, id} = key -> {id, cache.items[key].value}
      _ -> nil
    end)
  end

  @doc "Peek at a derived value without changing its ownership or LRU order."
  def peek(namespace, id) do
    case stats().items[{namespace, id}] do
      %{value: value} -> {:ok, value}
      nil -> :error
    end
  end

  def fetch(namespace, id, count_limit, build) do
    key = {namespace, id}
    cache = stats()

    case cache.items[key] do
      %{value: value} ->
        Process.put(@key, %{cache | order: [key | List.delete(cache.order, key)]})
        value

      nil ->
        value = build.()
        # Charge source keys as well as derived values. Conservative serialized
        # weight covers term overhead without per-frame heap traversal. Shared
        # terms may be over-counted, intentionally preferring eviction.
        bytes = 3 * :erlang.external_size({id, value})
        limit = Process.get({__MODULE__, :limit}, @default_bytes)

        if bytes <= limit do
          cache = stats()
          record = %{value: value, bytes: bytes, owner: Process.get({__MODULE__, :owner})}

          cache = %{
            cache
            | items: Map.put(cache.items, key, record),
              order: [key | cache.order],
              bytes: cache.bytes + bytes
          }

          cache = trim_namespace(cache, namespace, count_limit)
          Process.put(@key, trim_bytes(cache, limit))
        end

        value
    end
  end

  def drop_owner(owner), do: reject(fn _, item -> item.owner == owner end)
  def drop_namespace(module), do: reject(fn {{mod, _}, _}, _ -> mod == module end)

  defp reject(pred) do
    cache = stats()

    cache =
      Enum.reduce(cache.items, cache, fn {key, item}, acc ->
        if pred.(key, item), do: remove(acc, key), else: acc
      end)

    Process.put(@key, cache)
    :ok
  end

  defp trim_namespace(cache, namespace, limit) do
    keys = Enum.filter(cache.order, fn {ns, _} -> ns == namespace end)
    Enum.reduce(Enum.drop(keys, limit), cache, &remove(&2, &1))
  end

  defp trim_bytes(cache, limit) when cache.bytes <= limit, do: cache
  defp trim_bytes(cache, limit), do: trim_bytes(remove(cache, List.last(cache.order)), limit)

  defp remove(cache, key) do
    {item, items} = Map.pop(cache.items, key)
    %{cache | items: items, order: List.delete(cache.order, key), bytes: cache.bytes - item.bytes}
  end
end
