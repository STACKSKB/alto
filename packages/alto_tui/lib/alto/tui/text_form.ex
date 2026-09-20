defmodule Alto.TUI.TextForm do
  @moduledoc "Small state machine for popup forms backed by native text inputs."

  alias ExRatatui.Event.Key

  @editing_keys ~w(backspace delete left right home end)

  def new(kind, title, fields, opts \\ []) do
    fields =
      Enum.map(fields, fn {key, value, locked?} ->
        input = ExRatatui.text_input_new()
        ExRatatui.text_input_set_value(input, value || "")
        %{key: key, input: input, locked?: locked?}
      end)

    %{
      kind: kind,
      title: title,
      fields: fields,
      field_index: Keyword.get(opts, :field_index, 0),
      error: nil
    }
    |> Map.merge(Map.new(Keyword.drop(opts, [:field_index])))
  end

  def values(form), do: Map.new(form.fields, &{&1.key, ExRatatui.text_input_get_value(&1.input)})
  def value(form), do: ExRatatui.text_input_get_value(active_field(form).input)
  def key(_form, %Key{code: "esc"}), do: :cancel
  def key(_form, %Key{code: "s", modifiers: ["ctrl"]}), do: :submit
  def key(form, %Key{code: code}) when code in ["tab", "down"], do: {:edit, move(form, 1)}
  def key(form, %Key{code: code}) when code in ["back_tab", "up"], do: {:edit, move(form, -1)}

  def key(form, %Key{code: "enter"}) do
    if form.field_index == length(form.fields) - 1, do: :submit, else: {:edit, move(form, 1)}
  end

  def key(form, %Key{code: code, modifiers: modifiers}) do
    if modifiers == [] or code in @editing_keys,
      do: edit(form, &ExRatatui.text_input_handle_key(&1, code)),
      else: {:edit, form}
  end

  def paste(form, text), do: edit(form, &ExRatatui.text_input_insert_str(&1, text))

  def select(form, index) when index >= 0 and index < length(form.fields),
    do: %{form | field_index: index}

  def select(form, _index), do: form

  defp move(form, delta),
    do: %{form | field_index: Integer.mod(form.field_index + delta, length(form.fields))}

  defp edit(form, fun) do
    field = active_field(form)
    unless field.locked?, do: fun.(field.input)
    {:edit, %{form | error: nil}}
  end

  defp active_field(form), do: Enum.at(form.fields, form.field_index)
end
