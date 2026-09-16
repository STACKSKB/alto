defmodule Alto.TUI.WorkspaceForm do
  @moduledoc "Shared folder picker with highlighted suggestions and Tab completion."
  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Clear, Paragraph, TextInput, List}

  def new(base, host \\ "this computer", folders \\ [], opts \\ []) do
    %{
      kind: :workspace_form,
      input: ExRatatui.text_input_new(),
      base: base,
      folders: Enum.uniq(folders),
      suggestions: [],
      suggestion_index: 0,
      choose?: false,
      complete: Keyword.get(opts, :complete, &Alto.Harness.Folders.complete(&1, base)),
      revision: make_ref(),
      host: host,
      error: nil
    }
    |> refresh()
  end

  def path(form), do: ExRatatui.text_input_get_value(form.input)
  def key(_form, %Key{code: "esc"}), do: :cancel

  def key(form, %Key{code: "enter"}),
    do: {:submit, if(form.choose?, do: selected(form) || path(form), else: path(form))}

  def key(%{suggestions: [_ | _]} = form, %Key{code: code})
      when code in ["up", "down", "back_tab"] do
    delta = if code == "down", do: 1, else: -1

    index =
      if form.choose?,
        do: Integer.mod(form.suggestion_index + delta, length(form.suggestions)),
        else: 0

    {:edit, %{form | suggestion_index: index, choose?: true, error: nil}}
  end

  def key(form, %Key{code: "tab"}) do
    if selected(form) do
      ExRatatui.text_input_set_value(form.input, selected(form))
      ExRatatui.text_input_handle_key(form.input, "end")
    end

    {:edit, refresh(form)}
  end

  def key(form, %Key{code: "u", modifiers: ["ctrl"]}) do
    ExRatatui.text_input_set_value(form.input, "")
    {:edit, refresh(form)}
  end

  def key(form, %Key{code: code, modifiers: modifiers}) do
    if modifiers == [] and
         (String.length(code || "") == 1 or
            code in ["backspace", "delete", "left", "right", "home", "end"]),
       do: ExRatatui.text_input_handle_key(form.input, code)

    {:edit, refresh(form)}
  end

  def paste(form, text) do
    ExRatatui.text_input_insert_str(form.input, text)
    refresh(form)
  end

  defp selected(form), do: Enum.at(form.suggestions, form.suggestion_index)

  defp refresh(form) do
    suggestions = if form.complete, do: form.complete.(path(form)), else: {:ok, []}
    form = %{form | revision: make_ref(), choose?: false, suggestion_index: 0, error: nil}
    suggest(form, suggestions)
  end

  def suggest(form, result) do
    query = path(form)

    saved =
      Enum.filter(
        form.folders,
        &(query == "" or String.starts_with?(&1, Path.expand(query, form.base)))
      )

    found =
      case result do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    suggestions =
      Enum.uniq(Enum.map(saved, &(String.trim_trailing(&1, "/") <> "/")) ++ found)
      |> Enum.take(50)

    %{form | suggestions: suggestions, suggestion_index: 0}
  end

  def rect(width, height) do
    w = min(max(width - 4, 1), 88)
    h = min(max(height, 1), 18)
    %Rect{x: max(div(width - w, 2), 0), y: max(div(height - h, 2), 0), width: w, height: h}
  end

  def widgets(form, %{width: width, height: height}) do
    rect = rect(width, height)

    inner = %{
      rect
      | x: rect.x + 1,
        y: rect.y + 1,
        width: max(rect.width - 2, 0),
        height: max(rect.height - 2, 0)
    }

    bg = %Style{fg: :white, bg: :dark_gray}
    button_row = max(inner.height - 3, 4)
    text = "Folder on #{form.host}\nRelative paths start from: #{form.base}"

    [
      {%Clear{}, rect},
      {%Paragraph{
         text: text,
         style: bg,
         block: %Block{title: " Open folder · ^G W ", borders: [:all]}
       }, rect},
      {%TextInput{
         state: form.input,
         placeholder: "/path/to/project",
         style: bg,
         cursor_style: %Style{modifiers: [:reversed]}
       }, %{inner | y: inner.y + 2, height: min(inner.height, 1)}},
      {%List{
         items: form.suggestions,
         selected: if(form.suggestions == [], do: nil, else: form.suggestion_index),
         highlight_symbol: "› ",
         highlight_style: %Style{fg: :black, bg: :light_blue},
         style: bg
       }, %{inner | y: inner.y + 4, height: max(button_row - 4, 0)}},
      {%Paragraph{
         text:
           "[ Open folder ]  [ Cancel ]\n↑↓ choose · Tab complete · Enter open · Esc cancel\n#{form.error || ""}",
         style: bg
       }, %{inner | y: inner.y + button_row, height: min(inner.height, 3)}}
    ]
  end

  @doc "Only the entered path is selectable by default, not picker controls."
  def selection_content(form, width, height) do
    rect = rect(width, height)

    if path(form) == "",
      do: [],
      else: [
        %Rect{
          x: rect.x + 1,
          y: rect.y + 3,
          width: max(rect.width - 2, 0),
          height: min(max(rect.height - 2, 0), 1)
        }
      ]
  end

  def click(form, row, column, height \\ 18) do
    button_row = max(height - 5, 4)
    visible = max(button_row - 4, 0)
    offset = max(form.suggestion_index - visible + 1, 0)

    cond do
      row == button_row and column in 0..14 ->
        {:submit, path(form)}

      row == button_row and column in 17..26 ->
        :cancel

      row >= 4 and row < button_row and row - 4 + offset < length(form.suggestions) ->
        key(%{form | suggestion_index: row - 4 + offset, choose?: true}, %Key{code: "tab"})

      true ->
        {:edit, form}
    end
  end
end
