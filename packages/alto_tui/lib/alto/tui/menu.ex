defmodule Alto.TUI.Menu do
  @moduledoc "Searchable action and editable-field menus for terminal backends."
  alias ExRatatui.Event.Key

  @editing_keys ~w(backspace delete left right home end)

  def new(kind, title, items, selected \\ nil) do
    items =
      Enum.map(
        items,
        &Map.update!(&1, :label, fn label -> String.replace(label, ["\n", "\r"], " ") end)
      )

    %{
      kind: kind,
      title: title,
      items: items,
      filter: "",
      index: Enum.find_index(items, &(&1[:value] == selected)) || 0
    }
  end

  def form(kind, title, fields, opts) do
    fields =
      Enum.map(fields, fn {key, label, value, options} ->
        input = ExRatatui.text_input_new()
        ExRatatui.text_input_set_value(input, value || "")

        Map.merge(Map.new(options), %{
          key: key,
          label: label <> if(options[:locked?], do: " (fixed)", else: ""),
          input: input
        })
      end)

    on_action = Keyword.fetch!(opts, :on_action)
    actions = Enum.zip(opts[:buttons], opts[:actions] || [:submit, :cancel])

    items =
      fields ++
        Enum.map(actions, fn {label, action} ->
          %{label: label, action: &on_action.(&1, action)}
        end)

    new(kind, title, items)
    |> Map.merge(Map.new(Keyword.drop(opts, [:buttons, :actions, :field_index, :on_action])))
    |> Map.merge(%{
      editor?: true,
      index: opts[:field_index] || 0,
      error: nil,
      submit: &on_action.(&1, :submit)
    })
  end

  def field(menu, key), do: Enum.find(menu.items, &(&1[:key] == key))
  def value(menu, key), do: ExRatatui.text_input_get_value(field(menu, key).input)

  def values(menu) do
    for %{key: key, input: input} <- menu.items,
        into: %{},
        do: {key, ExRatatui.text_input_get_value(input)}
  end

  def selected(menu), do: Enum.at(items(menu), menu.index)

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

  def window(menu, height) do
    offset = max(menu.index - max(height, 1) + 1, 0)
    {Enum.slice(items(menu), offset, max(height, 0)), offset}
  end

  def key(_menu, %Key{code: "esc"}), do: :cancel
  def key(%{submit: submit}, %Key{code: "s", modifiers: ["ctrl"]}), do: {:action, submit}

  def key(menu, %Key{code: code}) when code in ["tab", "down", "back_tab", "up"],
    do: {:edit, move(menu, if(code in ["back_tab", "up"], do: -1, else: 1))}

  def key(menu, %Key{code: "enter"}) do
    if selected(menu)[:input] do
      if Enum.any?(Enum.drop(menu.items, menu.index + 1), & &1[:input]),
        do: {:edit, move(menu, 1)},
        else: {:action, menu.submit}
    else
      :select
    end
  end

  def key(menu, %Key{code: code, modifiers: modifiers}) do
    case selected(menu) do
      %{input: _} ->
        cond do
          code == "u" and modifiers == ["ctrl"] ->
            edit(menu, &ExRatatui.text_input_set_value(&1, ""))

          Enum.all?(modifiers, &(&1 == "shift")) or code in @editing_keys ->
            edit(menu, &ExRatatui.text_input_handle_key(&1, code))

          true ->
            menu
        end

      _ ->
        cond do
          code in ["j", "k"] ->
            move(menu, if(code == "k", do: -1, else: 1))

          code == "backspace" and menu[:editor?] != true ->
            filter(menu, String.slice(menu.filter, 0, max(String.length(menu.filter) - 1, 0)))

          menu[:editor?] != true and is_binary(code) and modifiers == [] and
            String.printable?(code) and
              String.length(code) == 1 ->
            filter(menu, menu.filter <> code)

          true ->
            menu
        end
    end
    |> then(&{:edit, &1})
  end

  def paste(menu, text) do
    case selected(menu) do
      %{input: _} -> edit(menu, &ExRatatui.text_input_insert_str(&1, text))
      _ -> if menu[:editor?], do: menu, else: filter(menu, menu.filter <> text)
    end
  end

  def masked_state(%{input: input}) do
    {value, cursor, offset} = ExRatatui.Native.text_input_snapshot(input)
    {String.duplicate("•", length(String.codepoints(value))), cursor, offset}
  end

  defp edit(menu, fun) do
    field = selected(menu)
    unless field[:locked?], do: fun.(field.input)
    %{menu | error: nil}
  end
end
