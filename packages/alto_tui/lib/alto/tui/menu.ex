defmodule Alto.TUI.Menu do
  @moduledoc "Pure searchable menu state shared by terminal backends."

  def new(kind, title, items, selected \\ nil) do
    %{
      kind: kind,
      title: title,
      items: items,
      filter: "",
      index: Enum.find_index(items, &(&1.value == selected)) || 0
    }
  end

  def items(%{filter: "", items: items}), do: items

  def items(menu) do
    query = String.downcase(menu.filter)
    Enum.filter(menu.items, &String.contains?(String.downcase(&1.label), query))
  end

  def title(%{filter: "", title: title}), do: title
  def title(menu), do: menu.title <> " · filter: " <> menu.filter

  def filter(menu, query), do: %{menu | filter: query, index: 0}

  def move(menu, delta) do
    count = length(items(menu))
    if count == 0, do: menu, else: %{menu | index: Integer.mod(menu.index + delta, count)}
  end
end
