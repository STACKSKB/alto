defmodule Alto.TUI.WorkspaceForm do
  @moduledoc "Shared folder-entry dialog for local and service-backed workspaces."
  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Clear, Paragraph, TextInput}

  def new(base, host \\ "this computer", folders \\ []) do
    %{
      kind: :workspace_form,
      input: ExRatatui.text_input_new(),
      base: base,
      folders: Enum.uniq(folders),
      folder_index: nil,
      host: host,
      error: nil
    }
  end

  def path(form), do: ExRatatui.text_input_get_value(form.input)

  def key(_form, %Key{code: "esc"}), do: :cancel
  def key(form, %Key{code: "enter"}), do: {:submit, path(form)}

  def key(%{folders: [_ | _]} = form, %Key{code: code}) when code in ["up", "down"] do
    count = length(form.folders)

    index =
      if is_nil(form.folder_index),
        do: 0,
        else: Integer.mod(form.folder_index + if(code == "down", do: 1, else: -1), count)

    ExRatatui.text_input_set_value(form.input, Enum.at(form.folders, index))
    ExRatatui.text_input_handle_key(form.input, "end")
    {:edit, %{form | folder_index: index, error: nil}}
  end

  def key(form, %Key{code: "u", modifiers: ["ctrl"]}) do
    ExRatatui.text_input_set_value(form.input, "")
    {:edit, %{form | error: nil}}
  end

  def key(form, %Key{code: code, modifiers: modifiers}) do
    if modifiers == [] and
         (String.length(code || "") == 1 or
            code in ["backspace", "delete", "left", "right", "home", "end"]) do
      ExRatatui.text_input_handle_key(form.input, code)
    end

    {:edit, %{form | error: nil}}
  end

  def paste(form, text) do
    ExRatatui.text_input_insert_str(form.input, text)
    %{form | error: nil}
  end

  def rect(width, height) do
    w = min(max(width - 4, 1), 88)
    h = min(max(height, 1), 12)
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

    hint =
      if form.folders == [],
        do: "Ctrl+U clears the path · Esc cancels",
        else: "↑↓ saved folders · Ctrl+U clear · Esc cancel"

    text =
      "Folder on #{form.host}\nRelative paths start from: #{form.base}\n\n\nEnter opens an existing folder for a new task.\n[ Open workspace ]  [ Cancel ]\n#{hint}\n#{form.error || ""}"

    [
      {%Clear{}, rect},
      {%Paragraph{
         text: text,
         style: bg,
         block: %Block{title: " New workspace · Enter open · Esc cancel ", borders: [:all]}
       }, rect},
      {%TextInput{
         state: form.input,
         placeholder: "/path/to/project",
         style: bg,
         cursor_style: %Style{modifiers: [:reversed]}
       }, %{inner | y: inner.y + 2, height: min(inner.height, 1)}}
    ]
  end

  @doc "Only the entered path is selectable by default, not dialog instructions."
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

  # Rows are relative to the dialog's inner rectangle.
  def click(form, row, column) do
    cond do
      row == 5 and column >= 0 and column < 18 -> {:submit, path(form)}
      row == 5 and column in 20..29 -> :cancel
      true -> {:edit, form}
    end
  end
end
