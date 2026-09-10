defmodule Alto.TUI.View do
  @moduledoc "ExRatatui renderer and deterministic hit targets for Alto's terminal client."

  alias Alto.TUI.Layout, as: PaneLayout
  alias Alto.TUI.State
  alias Alto.Usage
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Clear, List, Paragraph, Popup, Textarea}

  @accent {:rgb, 105, 180, 255}
  @muted {:rgb, 116, 126, 140}
  @panel {:rgb, 23, 28, 36}
  @panel_alt {:rgb, 29, 36, 46}

  @doc "Render one complete frame."
  def widgets(%State{} = state, %{width: width, height: height}) do
    layout = layout(state, width, height)

    []
    |> maybe_add(rail_widget(state), layout.rail)
    |> add(transcript_widget(state), layout.transcript)
    |> add(settings_widget(state), layout.settings)
    |> add(composer_widget(state), layout.composer)
    |> add_details(state, layout.details, :pane)
    |> add(status_widget(state, width), layout.status)
    |> add_context_drawer(state, layout)
    |> add_overlay(state.overlay, layout.root)
  end

  @doc "Calculate the same geometry used for rendering and mouse routing."
  def layout(%State{} = state, width, height) do
    PaneLayout.calculate(width, height,
      rail_visible: state.rail_visible?,
      details_visible: state.details_visible?,
      rail_width: state.rail_width,
      details_width: state.details_width
    )
  end

  @doc "Resolve mouse coordinates to a semantic UI target."
  def hit_target(%State{overlay: overlay}, width, height, x, y) when not is_nil(overlay) do
    popup = overlay_rect(overlay, width, height)

    if PaneLayout.contains?(popup, x, y) do
      row = y - popup.y - 1
      if row >= 0, do: {:overlay_row, row}, else: :overlay
    else
      :overlay_outside
    end
  end

  def hit_target(%State{} = state, width, height, x, y) do
    layout = layout(state, width, height)
    context_overlay = context_overlay_rect(state, width, height)

    cond do
      PaneLayout.contains?(context_overlay, x, y) ->
        details_target(state, context_overlay, x, y)

      context_overlay ->
        :details_drawer_outside

      layout.left_seam && abs(x - layout.left_seam) <= 0 ->
        :left_seam

      layout.right_seam && abs(x - layout.right_seam) <= 0 ->
        :right_seam

      PaneLayout.contains?(layout.rail, x, y) ->
        {:rail_row, y - layout.rail.y - 1}

      PaneLayout.contains?(layout.settings, x, y) ->
        settings_target(state, layout.settings, x)

      PaneLayout.contains?(layout.composer, x, y) ->
        :composer

      PaneLayout.contains?(layout.details, x, y) ->
        details_target(state, layout.details, x, y)

      PaneLayout.contains?(layout.transcript, x, y) ->
        :transcript

      true ->
        :none
    end
  end

  @doc "Rectangle used by narrow context, or nil when the persistent pane is active."
  def context_overlay_rect(%State{details_drawer_open?: false}, _width, _height), do: nil

  def context_overlay_rect(%State{}, width, height) when width <= 0 or height <= 1, do: nil

  def context_overlay_rect(%State{} = state, width, height) do
    layout = layout(state, width, height)

    if layout.details do
      nil
    else
      main_height = layout.status.y
      fullscreen? = context_fullscreen?(state, width)
      drawer_width = min(max(div(width * state.narrow_context_width, 100), 1), width)

      if fullscreen? do
        %Rect{x: 0, y: 0, width: width, height: main_height}
      else
        %Rect{x: width - drawer_width, y: 0, width: drawer_width, height: main_height}
      end
    end
  end

  defp rail_widget(state) do
    rows = State.rail_rows(state)

    %List{
      items: Enum.map(rows, & &1.label),
      selected: selected_rail_index(state, rows),
      highlight_symbol: "› ",
      highlight_style: style(fg: @accent, bg: @panel_alt, modifiers: [:bold]),
      style: style(fg: :gray, bg: @panel),
      block: block(" workspaces ", state.focus == :rail)
    }
  end

  defp transcript_widget(state) do
    text = transcript_text(state)

    task_title =
      case State.selected_task(state) do
        nil -> " new task "
        task -> " # " <> task["title"] <> " "
      end

    title =
      if state.transcript_follow?,
        do: task_title,
        else: " ↑ history · G follow ·" <> task_title

    %Paragraph{
      text: text,
      wrap: true,
      scroll: {transcript_scroll(state), 0},
      style: style(fg: :white),
      block: block(title, state.focus == :transcript)
    }
  end

  defp settings_widget(state) do
    %Paragraph{
      text: Line.new(Enum.map(settings_segments(state), &segment_span/1)),
      style: style(bg: @panel_alt),
      block: nil
    }
  end

  defp composer_widget(state) do
    title =
      if state.leader?,
        do: gear_title(state),
        else: composer_title(state)

    if state.composer_mode == :code do
      native_composer(state, title)
    else
      wrapped_composer(state, title)
    end
  end

  defp native_composer(state, title) do
    %Textarea{
      state: state.textarea,
      placeholder: "Paste or type code…",
      placeholder_style: style(fg: @muted),
      style: style(fg: :white, bg: @panel),
      cursor_style: style(fg: :black, bg: @accent),
      cursor_line_style: style(bg: @panel),
      block: block(title, state.focus == :composer)
    }
  end

  # ExRatatui 0.13's stateful textarea does not expose soft wrapping. Prose mode
  # therefore renders a wrapped, cursor-aware projection while retaining that
  # textarea as the sole editing state. Code mode above uses the native widget.
  defp wrapped_composer(state, title) do
    value = ExRatatui.textarea_get_value(state.textarea)
    {cursor_line, cursor_column} = ExRatatui.textarea_cursor(state.textarea)
    {text, cursor_row} = wrapped_composer_text(state, value, cursor_line, cursor_column)
    {_width, height} = composer_inner_size(state)
    scroll_y = if cursor_row, do: max(cursor_row - height + 1, 0), else: 0

    %Paragraph{
      text: text,
      wrap: false,
      scroll: {scroll_y, 0},
      style: style(fg: :white, bg: @panel),
      block: block(title, state.focus == :composer)
    }
  end

  defp wrapped_composer_text(state, "", _cursor_line, _cursor_column) do
    spans =
      if state.focus == :composer do
        [
          Span.new(" ", style: style(fg: :black, bg: @accent)),
          Span.new("Describe the next change…", style: style(fg: @muted))
        ]
      else
        [Span.new("Describe the next change…", style: style(fg: @muted))]
      end

    {Text.new([Line.new(spans)]), if(state.focus == :composer, do: 0, else: nil)}
  end

  defp wrapped_composer_text(state, value, cursor_line, cursor_column) do
    {width, _height} = composer_inner_size(state)

    {rows, cursor_row} =
      value
      |> String.split("\n", trim: false)
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {line, line_index}, {rows, found_cursor} ->
        graphemes = String.graphemes(line)
        cursor? = state.focus == :composer and line_index == cursor_line
        column = min(cursor_column, length(graphemes))
        projections = wrap_prose_line(graphemes, width)

        projections =
          maybe_add_end_cursor_row(projections, cursor?, column, length(graphemes), width)

        {display_cursor_row, display_cursor_column} =
          if cursor?, do: cursor_projection(projections, column, width), else: {nil, nil}

        start_row = length(rows)

        line_rows =
          projections
          |> Enum.with_index()
          |> Enum.map(fn {projection, row_index} ->
            if cursor? and row_index == display_cursor_row do
              cursor_spans(projection.graphemes, display_cursor_column)
            else
              Line.new([Span.new(Enum.join(projection.graphemes))])
            end
          end)

        cursor_row =
          if cursor?, do: start_row + display_cursor_row, else: found_cursor

        {rows ++ line_rows, cursor_row}
      end)

    {Text.new(rows), cursor_row}
  end

  defp wrap_prose_line([], _width), do: [%{graphemes: [], start: 0, stop: 0}]

  defp wrap_prose_line(graphemes, width), do: do_wrap_prose_line(graphemes, width, 0, [])

  defp do_wrap_prose_line(graphemes, width, offset, rows) when length(graphemes) <= width do
    rows ++ [%{graphemes: graphemes, start: offset, stop: offset + length(graphemes)}]
  end

  defp do_wrap_prose_line(graphemes, width, offset, rows) do
    window = Enum.take(graphemes, width)

    break_at =
      window
      |> Enum.with_index()
      |> Enum.filter(fn {grapheme, index} ->
        whitespace?(grapheme) and index > 0 and
          Enum.any?(Enum.take(window, index), &(not whitespace?(&1)))
      end)
      |> Elixir.List.last()
      |> case do
        {_grapheme, index} -> index
        nil -> width
      end

    {display, consumed} =
      if break_at < width do
        {Enum.take(graphemes, break_at), break_at + 1}
      else
        {window, width}
      end

    row = %{graphemes: display, start: offset, stop: offset + break_at}

    do_wrap_prose_line(
      Enum.drop(graphemes, consumed),
      width,
      offset + consumed,
      rows ++ [row]
    )
  end

  defp maybe_add_end_cursor_row(rows, true, column, content_length, width)
       when column == content_length do
    case Elixir.List.last(rows) do
      %{graphemes: graphemes, stop: ^content_length} when length(graphemes) == width ->
        rows ++ [%{graphemes: [], start: content_length, stop: content_length}]

      _other ->
        rows
    end
  end

  defp maybe_add_end_cursor_row(rows, _cursor?, _column, _length, _width), do: rows

  defp cursor_projection(rows, column, width) do
    last_index = length(rows) - 1

    index =
      rows
      |> Enum.with_index()
      |> Enum.find_value(last_index, fn {row, index} ->
        next = Enum.at(rows, index + 1)

        cond do
          column < row.stop -> index
          column > row.stop -> nil
          is_nil(next) -> index
          next.start > row.stop -> index
          length(row.graphemes) < width -> index
          true -> nil
        end
      end)

    row = Enum.at(rows, index)
    {index, column |> Kernel.-(row.start) |> max(0) |> min(length(row.graphemes))}
  end

  defp whitespace?(grapheme), do: String.match?(grapheme, ~r/^\s$/u)

  defp cursor_spans(graphemes, column) do
    {before, rest} = Enum.split(graphemes, column)

    case rest do
      [cursor | trailing] ->
        Line.new([
          Span.new(Enum.join(before)),
          Span.new(cursor, style: style(fg: :black, bg: @accent)),
          Span.new(Enum.join(trailing))
        ])

      [] ->
        Line.new([
          Span.new(Enum.join(before)),
          Span.new(" ", style: style(fg: :black, bg: @accent))
        ])
    end
  end

  defp composer_inner_size(state) do
    {width, height} = state.dimensions
    composer = layout(state, width, height).composer
    {max(composer.width - 2, 1), max(composer.height - 2, 1)}
  end

  defp composer_title(%{composer_mode: :code} = state),
    do: " code entry · NOWRAP · F6 prose" <> composer_activity_hint(state) <> " "

  defp composer_title(state),
    do: " message · WRAP · F6 code" <> composer_activity_hint(state) <> " "

  defp composer_activity_hint(state) do
    if active_run?(state), do: " · Enter queue · Esc stop", else: " · Enter send"
  end

  defp active_run?(state) do
    Enum.any?(state.runs, fn {_id, run} -> run.task_id == state.selected_task_id end)
  end

  defp gear_title(state) do
    {width, _height} = composer_inner_size(state)

    if width < 90 do
      " gear: B A P M E W T N D Q · Esc cancel "
    else
      " gear: B backend · A approval · P provider · M model · E entry · W workspace · T task · N new · D details · Q quit "
    end
  end

  @doc "Largest useful vertical transcript offset for the current viewport."
  def transcript_bottom_scroll(state) do
    {width, height} = state.dimensions
    transcript = layout(state, width, height).transcript
    inner_width = max(transcript.width - 2, 1)
    inner_height = max(transcript.height - 2, 1)

    row_count =
      state
      |> transcript_text()
      |> String.split("\n", trim: false)
      |> Enum.reduce(0, fn line, count ->
        count + length(wrap_prose_line(String.graphemes(line), inner_width))
      end)

    max(row_count - inner_height, 0)
  end

  defp transcript_text(state) do
    case State.current_entries(state) do
      [] ->
        "Welcome to Alto. Start typing below.\n\n" <>
          "^G gear · B backend · A approval · P provider · M model · E entry mode · W workspace · T task · N new · D details · Q quit"

      entries ->
        entries
        |> Enum.map(&format_entry/1)
        |> Enum.join("\n\n")
    end
  end

  defp transcript_scroll(%{transcript_follow?: true} = state),
    do: transcript_bottom_scroll(state)

  defp transcript_scroll(state),
    do: min(state.transcript_scroll, transcript_bottom_scroll(state))

  defp details_widget(state, presentation) do
    {title, text} = details_content(state, presentation)

    title =
      if presentation == :drawer,
        do: title <> "│ click header / Esc close ",
        else: title

    %Paragraph{
      text: text,
      wrap: true,
      scroll: {state.details_scroll, 0},
      style: style(fg: :gray, bg: @panel),
      block: block(title, state.focus == :details)
    }
  end

  defp add_details(widgets, _state, nil, _presentation), do: widgets

  defp add_details(widgets, %{pending_approvals: []} = state, rect, presentation),
    do: add(widgets, details_widget(state, presentation), rect)

  defp add_details(widgets, state, rect, presentation) do
    details = details_widget(state, presentation)
    controls = approval_controls(rect)

    content = %Rect{
      x: rect.x + 1,
      y: rect.y + 1,
      width: max(rect.width - 2, 0),
      height: max(rect.height - 2 - length(controls), 0)
    }

    widgets =
      widgets
      |> add(%{details | text: "", scroll: {0, 0}}, rect)
      |> add(%{details | block: nil}, content)

    Enum.reduce(controls, widgets, fn control, acc ->
      button = %Paragraph{
        text: control.label,
        style: style(fg: :black, bg: @accent, modifiers: [:bold])
      }

      add(acc, button, control.rect)
    end)
  end

  # Rendering and hit testing share these rectangles; only a visible button
  # can submit a decision. The actions remain fixed while the details scroll.
  defp approval_controls(rect) when rect.height >= 4 and rect.width >= 16 do
    [{:approve, "[ Approve F8 ]"}, {:deny, "[ Deny F9 ]"}]
    |> Enum.with_index()
    |> Enum.map(fn {{decision, label}, index} ->
      %{
        decision: decision,
        label: label,
        rect: %Rect{
          x: rect.x + 1,
          y: rect.y + rect.height - 3 + index,
          width: String.length(label),
          height: 1
        }
      }
    end)
  end

  defp approval_controls(_rect), do: []

  defp add_context_drawer(widgets, state, layout) do
    case context_overlay_rect(state, layout.root.width, layout.root.height) do
      nil -> widgets
      rect -> widgets |> add(%Clear{}, rect) |> add_details(state, rect, :drawer)
    end
  end

  defp status_widget(state, width) do
    usage = State.current_usage(state)
    project = State.selected_project(state)
    task = State.selected_task(state)
    activity = State.run_label(state)

    left =
      " alto │ " <>
        String.upcase(Atom.to_string(state.selected_backend)) <>
        " │ " <>
        short(project && project["name"], 18) <>
        " / " <>
        short((task && task["title"]) || "new task", 28) <>
        " │ " <> activity

    right =
      "tok #{compact(usage.total_tokens)}  ↑#{compact(usage.input_tokens)}  ↓#{compact(usage.output_tokens)}" <>
        "  ctx #{context_consumption(state, usage)}  cache #{Float.round(Usage.cache_hit_rate(usage), 1)}%" <>
        quota_suffix(state) <> " "

    message = if state.notice, do: " │ " <> short(state.notice, 32), else: ""
    left = left <> message

    text =
      if width > String.length(right) + 12 do
        left_width = width - String.length(right)

        if left_width >= String.length(left) do
          String.pad_trailing(short(left, left_width), left_width) <> right
        else
          compact_status_line(activity, message, right, width)
        end
      else
        compact_status_line(activity, message, right, width)
      end

    %Paragraph{
      text: text,
      style: style(fg: :black, bg: @accent, modifiers: [:bold])
    }
  end

  defp compact_status_line(activity, message, right, width) do
    prefix = " " <> activity <> message
    remaining = max(width - String.length(prefix) - 3, 0)
    suffix = if remaining > 0, do: " │ " <> String.slice(right, 0, remaining), else: ""
    String.slice(prefix <> suffix, 0, width)
  end

  defp add_overlay(widgets, nil, _root), do: widgets

  defp add_overlay(widgets, %{kind: :provider_form} = overlay, root) do
    popup = %Popup{
      content: %Paragraph{
        text: provider_form_text(overlay, root.width),
        wrap: false,
        style: style(fg: :white, bg: @panel_alt)
      },
      block: %Block{
        title: " #{overlay.title} │ Tab/↑↓ fields · Enter next/save · ^S save · Esc ",
        borders: [:all],
        border_type: :rounded,
        border_style: style(fg: @accent),
        style: style(bg: @panel_alt)
      },
      percent_width: 72,
      percent_height: 66
    }

    widgets ++ [{popup, root}]
  end

  defp add_overlay(widgets, %{kind: :model_form} = overlay, root) do
    value = ExRatatui.text_input_get_value(overlay.input)
    cursor = ExRatatui.text_input_cursor(overlay.input)
    error = if overlay.error, do: "  ! " <> overlay.error, else: ""

    popup = %Popup{
      content: %Paragraph{
        text: model_form_text(value, cursor, error, root.width),
        wrap: false,
        style: style(fg: :white, bg: @panel_alt)
      },
      block: %Block{
        title: " #{overlay.title} │ Enter use · Esc ",
        borders: [:all],
        border_type: :rounded,
        border_style: style(fg: @accent),
        style: style(bg: @panel_alt)
      },
      percent_width: 62,
      percent_height: 42
    }

    widgets ++ [{popup, root}]
  end

  defp add_overlay(widgets, overlay, root) do
    selected = safe_selected(overlay.index, overlay.items)

    list = %List{
      items: Enum.map(overlay.items, & &1.label),
      selected: selected,
      highlight_symbol: "› ",
      highlight_style: style(fg: :black, bg: @accent, modifiers: [:bold]),
      style: style(fg: :white, bg: @panel_alt)
    }

    content =
      if is_binary(Map.get(overlay, :message)) do
        %Paragraph{
          text:
            overlay_message_prefix(overlay) <>
              overlay.message <>
              "\n\n" <>
              (overlay.items
               |> Enum.with_index()
               |> Enum.map_join("\n", fn {item, index} ->
                 if index == selected, do: "› " <> item.label, else: "  " <> item.label
               end)),
          wrap: true,
          style: style(fg: :white, bg: @panel_alt)
        }
      else
        list
      end

    popup = %Popup{
      content: content,
      block: %Block{
        title: " #{overlay.title} │ ↑↓ · Enter · Esc ",
        borders: [:all],
        border_type: :rounded,
        border_style: style(fg: @accent),
        style: style(bg: @panel_alt)
      },
      percent_width: 62,
      percent_height: 62
    }

    widgets ++ [{popup, root}]
  end

  defp provider_form_text(overlay, root_width) do
    values = Map.new(overlay.fields, &{&1.key, ExRatatui.text_input_get_value(&1.input)})
    active = overlay.field_index
    key = Map.get(values, :api_key, "")

    key_display =
      cond do
        key != "" -> String.duplicate("•", min(length(String.codepoints(key)), 32))
        overlay.key_saved? -> "(saved — leave blank to keep)"
        true -> "(optional for local providers)"
      end

    lines = [
      plain_line("  Credentials are saved privately outside the workspace."),
      plain_line(""),
      form_line(overlay, active, 0, :id, "ID", Map.get(values, :id, ""),
        locked?: locked?(overlay, :id),
        max_width: provider_value_width(root_width, locked?(overlay, :id))
      ),
      form_line(overlay, active, 1, :label, "Name", Map.get(values, :label, ""),
        max_width: provider_value_width(root_width, false)
      ),
      form_line(overlay, active, 2, :base_url, "Base URL", Map.get(values, :base_url, ""),
        max_width: provider_value_width(root_width, false)
      ),
      form_line(overlay, active, 3, :api_key, "API key", key_display,
        placeholder?: key == "",
        raw_value: key,
        max_width: provider_value_width(root_width, false)
      ),
      form_line(overlay, active, 4, :model, "Default model", Map.get(values, :model, ""),
        max_width: provider_value_width(root_width, false)
      ),
      plain_line(if(overlay.error, do: "  ! " <> overlay.error, else: "")),
      plain_line("  [ Save provider ]"),
      plain_line("  [ Cancel ]")
    ]

    Text.new(lines)
  end

  defp model_form_text(value, cursor, error, root_width) do
    max_width = max(div(root_width * 62, 100) - 2 - String.length("› Model ID  "), 1)

    Text.new([
      plain_line("  Use the provider's exact model identifier."),
      plain_line(""),
      Line.new([Span.new("› Model ID  ") | editable_value_spans(value, cursor, max_width)]),
      plain_line(error),
      plain_line(""),
      plain_line("  [ Use model ]"),
      plain_line("  [ Cancel ]")
    ])
  end

  defp plain_line(value), do: Line.new([Span.new(value)])

  defp form_line(overlay, active, index, key, label, value, opts) do
    locked? = Keyword.get(opts, :locked?, false)
    placeholder? = Keyword.get(opts, :placeholder?, false)
    raw_value = Keyword.get(opts, :raw_value, value)
    max_width = Keyword.get(opts, :max_width, 40)
    marker = if active == index, do: "›", else: " "
    suffix = if locked?, do: "  (fixed)", else: ""
    prefix = marker <> " " <> String.pad_trailing(label, 14)

    value_spans =
      if active == index and not locked? do
        field = Enum.find(overlay.fields, &(&1.key == key))
        cursor = if field, do: ExRatatui.text_input_cursor(field.input), else: 0

        if placeholder? do
          editable_value_spans("", cursor, max_width) ++
            [Span.new(value, style: style(fg: @muted))]
        else
          if key == :api_key do
            masked_value_spans(raw_value, cursor, max_width)
          else
            editable_value_spans(value, cursor, max_width)
          end
        end
      else
        [Span.new(value)]
      end

    Line.new([Span.new(prefix) | value_spans ++ [Span.new(suffix)]])
  end

  defp provider_value_width(root_width, locked?) do
    popup_content_width = max(div(root_width * 72, 100) - 2, 1)
    suffix_width = if locked?, do: String.length("  (fixed)"), else: 0
    max(popup_content_width - String.length("› ") - 14 - suffix_width, 1)
  end

  # Keep the insertion point visible when a URL or model identifier is longer
  # than the popup. The displayed value is still the real value (or its mask);
  # only the far end away from the cursor is elided.
  defp editable_value_spans(value, cursor, max_width) do
    editable_codepoint_spans(String.codepoints(value), cursor, max_width)
  end

  defp masked_value_spans(value, cursor, max_width) do
    value
    |> String.codepoints()
    |> Enum.map(fn _grapheme -> "•" end)
    |> editable_codepoint_spans(cursor, max_width)
  end

  defp editable_codepoint_spans(graphemes, cursor, max_width) do
    cursor = min(max(cursor, 0), length(graphemes))
    max_width = max(max_width, 1)

    if length(graphemes) + 1 <= max_width do
      caret_spans(graphemes, cursor)
    else
      bounded_caret_spans(graphemes, cursor, max_width)
    end
  end

  defp bounded_caret_spans(_graphemes, _cursor, 1), do: caret_spans([], 0)

  defp bounded_caret_spans(graphemes, cursor, max_width) do
    edge_width = max_width - 2

    cond do
      cursor <= edge_width ->
        visible = Enum.take(graphemes, edge_width)
        caret_spans(visible, cursor) ++ [Span.new("…")]

      cursor >= length(graphemes) - edge_width ->
        start = max(length(graphemes) - edge_width, 0)
        visible = Enum.slice(graphemes, start, edge_width)
        [Span.new("…") | caret_spans(visible, cursor - start)]

      max_width < 4 ->
        caret_spans([], 0)

      true ->
        content_width = max_width - 3
        start = max(cursor - div(content_width, 2), 1)
        start = min(start, length(graphemes) - content_width - 1)
        visible = Enum.slice(graphemes, start, content_width)
        [Span.new("…") | caret_spans(visible, cursor - start)] ++ [Span.new("…")]
    end
  end

  defp caret_spans(graphemes, column) do
    {before, trailing} = Enum.split(graphemes, column)

    [
      Span.new(Enum.join(before)),
      Span.new("▏", style: style(fg: :black, bg: @accent)),
      Span.new(Enum.join(trailing))
    ]
  end

  defp locked?(overlay, key) do
    case Enum.find(overlay.fields, &(&1.key == key)) do
      %{locked?: locked?} -> locked?
      _other -> false
    end
  end

  @doc "Settings labels and exact click widths."
  def settings_segments(state) do
    profile = State.selected_profile(state)

    provider =
      if state.selected_backend == :codex,
        do: Alto.Codex.Backend.account_label(state.codex.account),
        else: (profile && profile.label) || "none"

    cond do
      ultra_compact_settings?(state) ->
        [
          %{target: {:setting, :backend}, text: " B:#{String.first(backend_label(state))} "},
          %{target: {:setting, :approval}, text: " A:#{mini_approval_label(state)} "},
          %{target: {:setting, :entry_mode}, text: " E:#{mini_entry_label(state)} "},
          %{target: {:setting, :details}, text: " D:#{mini_context_label(state)} "},
          %{target: {:setting, :provider}, text: " P:… "},
          %{target: {:setting, :model}, text: " M:… "}
        ]

      compact_settings?(state) ->
        label_width = compact_setting_label_width(state)

        [
          %{target: {:setting, :backend}, text: " B:#{backend_label(state)} "},
          %{target: {:setting, :approval}, text: " A:#{approval_label(state.approval_level)} "},
          %{target: {:setting, :entry_mode}, text: " E:#{entry_mode_label(state)} "},
          %{target: {:setting, :details}, text: " D:#{context_label(state)} "},
          %{target: {:setting, :provider}, text: " P:#{short(provider, label_width)} "},
          %{
            target: {:setting, :model},
            text: " M:#{short(state.selected_model || "choose…", label_width)} "
          }
        ]

      true ->
        [
          %{target: {:setting, :backend}, text: " backend #{backend_label(state)} "},
          %{
            target: {:setting, :approval},
            text: " approval #{approval_label(state.approval_level)} "
          },
          %{target: {:setting, :details}, text: " context #{context_label(state)} "},
          %{target: {:setting, :provider}, text: " provider #{short(provider, 16)} "},
          %{
            target: {:setting, :model},
            text: " model #{short(state.selected_model || "choose…", 20)} "
          },
          %{target: {:setting, :entry_mode}, text: " entry #{entry_mode_label(state)} "}
        ]
    end
  end

  defp settings_target(state, rect, x) do
    relative = x - rect.x

    settings_segments(state)
    |> Enum.reduce_while(0, fn segment, offset ->
      finish = offset + String.length(segment.text)

      if relative >= offset and relative < finish,
        do: {:halt, segment.target},
        else: {:cont, finish}
    end)
    |> case do
      target when is_tuple(target) -> target
      _offset -> :settings
    end
  end

  defp details_target(%{details_drawer_open?: true}, rect, _x, y) when y == rect.y,
    do: :details_close

  defp details_target(%{pending_approvals: [_ | _]}, rect, x, y) do
    Enum.find_value(approval_controls(rect), :details, fn control ->
      if PaneLayout.contains?(control.rect, x, y), do: {:approval, control.decision}
    end)
  end

  defp details_target(_state, _rect, _x, _y), do: :details

  defp details_content(%{pending_approvals: [%{request: request} | _]}, _presentation) do
    text =
      "#{request.tool}\n\n" <>
        "Arguments\n#{inspect(request.arguments, pretty: true, limit: 30)}\n\n" <>
        "Prepared\n#{inspect(request.details, pretty: true, limit: 30)}"

    {" approval required ", text}
  end

  defp details_content(state, presentation) do
    recent =
      state
      |> State.current_entries()
      |> Enum.filter(&(&1.kind in [:tool, :system, :error]))
      |> Enum.take(-12)
      |> Enum.map(fn entry ->
        case Map.get(entry, :detail) do
          detail when is_binary(detail) and detail != "" ->
            format_entry(entry) <> "\n" <> detail

          _other ->
            format_entry(entry)
        end
      end)
      |> Enum.join("\n\n")

    text =
      if recent == "" do
        instruction =
          if presentation == :drawer,
            do: "Esc, ^G D, the title, or a click outside closes context.",
            else: "^G D hides this pane. Drag either vertical seam to resize."

        "Contextual details appear here: approvals, tool activity, diffs, and generated handoff pointers.\n\n" <>
          instruction
      else
        recent
      end

    {" context ", text}
  end

  defp format_entry(%{kind: :user, text: text}), do: "you › " <> text
  defp format_entry(%{kind: :assistant, text: text}), do: "alto › " <> text
  defp format_entry(%{kind: :codex_assistant, text: text}), do: "codex › " <> text
  defp format_entry(%{kind: :tool, text: text}), do: "tool · " <> text
  defp format_entry(%{kind: :error, text: text}), do: "error ! " <> text
  defp format_entry(%{kind: :system, text: text}), do: "· " <> text
  defp format_entry(%{text: text}), do: text

  defp segment_span(segment),
    do: Span.new(segment.text, style: style(fg: :white, bg: @panel_alt, modifiers: [:bold]))

  defp selected_rail_index(state, rows) do
    target = state.selected_task_id || state.selected_project_id

    case Enum.find_index(rows, &(&1.id == target)) do
      nil -> safe_selected(0, rows)
      index -> index
    end
  end

  defp safe_selected(_index, []), do: nil
  defp safe_selected(index, items), do: index |> max(0) |> min(length(items) - 1)

  defp block(title, focused?) do
    %Block{
      title: title,
      borders: [:all],
      border_type: :plain,
      border_style: style(fg: if(focused?, do: @accent, else: @muted)),
      style: style(bg: @panel)
    }
  end

  defp popup_rect(width, height), do: popup_rect(width, height, 62, 62)

  defp overlay_rect(%{kind: :provider_form}, width, height),
    do: popup_rect(width, height, 72, 66)

  defp overlay_rect(%{kind: :model_form}, width, height),
    do: popup_rect(width, height, 62, 42)

  defp overlay_rect(_overlay, width, height), do: popup_rect(width, height)

  defp popup_rect(width, height, width_percent, height_percent) do
    popup_width = div(width * width_percent, 100)
    popup_height = div(height * height_percent, 100)

    %Rect{
      x: div(width - popup_width, 2),
      y: div(height - popup_height, 2),
      width: popup_width,
      height: popup_height
    }
  end

  defp compact(n) when n >= 1_000_000,
    do: :erlang.float_to_binary(n / 1_000_000, decimals: 1) <> "m"

  defp compact(n) when n >= 1_000, do: :erlang.float_to_binary(n / 1_000, decimals: 1) <> "k"
  defp compact(n), do: Integer.to_string(n)

  defp context_consumption(state, usage) do
    if state.selected_backend == :codex do
      context_percent(usage, state.codex.context_window)
    else
      native_context_consumption(state, usage)
    end
  end

  defp native_context_consumption(state, usage) do
    with model when is_binary(model) <- state.selected_model,
         models when is_list(models) <- Map.get(state.models, state.selected_provider_id),
         model_info when not is_nil(model_info) <- Enum.find(models, &(model_id(&1) == model)),
         context when is_integer(context) and context > 0 <- model_context(model_info) do
      percent = min(usage.last_input_tokens / context * 100.0, 999.9)
      "#{Float.round(percent, 1)}%"
    else
      _other -> "—"
    end
  end

  defp context_percent(usage, context) when is_integer(context) and context > 0 do
    percent = min(usage.last_input_tokens / context * 100.0, 999.9)
    "#{Float.round(percent, 1)}%"
  end

  defp context_percent(_usage, _context), do: "—"

  defp quota_suffix(%{selected_backend: :codex} = state) do
    case Alto.Codex.Backend.primary_rate_limit(state.codex.rate_limits) do
      %{"usedPercent" => used} when is_number(used) -> "  quota #{Float.round(used * 1.0, 1)}%"
      _other -> "  quota —"
    end
  end

  defp quota_suffix(_state), do: ""

  defp compact_settings?(state) do
    {width, height} = state.dimensions

    case layout(state, width, height).settings do
      %Rect{width: settings_width} -> settings_width < 112
      _other -> true
    end
  end

  defp ultra_compact_settings?(state) do
    {width, height} = state.dimensions

    case layout(state, width, height).settings do
      %Rect{width: settings_width} -> settings_width < 48
      _other -> true
    end
  end

  defp compact_setting_label_width(state) do
    {width, height} = state.dimensions

    case layout(state, width, height).settings do
      %Rect{width: settings_width} ->
        settings_width
        |> Kernel.-(39)
        |> div(2)
        |> max(1)
        |> min(13)

      _other ->
        1
    end
  end

  defp context_fullscreen?(%{narrow_context: :fullscreen}, _width), do: true
  defp context_fullscreen?(%{narrow_context: :drawer}, _width), do: false

  defp context_fullscreen?(state, width),
    do: width < state.narrow_context_fullscreen_below

  defp backend_label(state), do: state.selected_backend |> Atom.to_string() |> String.upcase()
  defp entry_mode_label(%{composer_mode: :code}), do: "CODE"
  defp entry_mode_label(_state), do: "PROSE"

  defp context_label(%{pending_approvals: [_ | _]}), do: "REQ"
  defp context_label(%{details_drawer_open?: true}), do: "OPEN"
  defp context_label(%{details_visible?: true}), do: "CTX"
  defp context_label(_state), do: "OFF"

  defp mini_approval_label(%{approval_level: :ask}), do: "?"
  defp mini_approval_label(%{approval_level: :read_only}), do: "R"
  defp mini_approval_label(_state), do: "!"

  defp mini_entry_label(%{composer_mode: :code}), do: "C"
  defp mini_entry_label(_state), do: "P"

  defp mini_context_label(%{pending_approvals: [_ | _]}), do: "!"
  defp mini_context_label(%{details_drawer_open?: true}), do: "O"
  defp mini_context_label(%{details_visible?: true}), do: "C"
  defp mini_context_label(_state), do: "X"

  defp overlay_message_prefix(%{kind: :model_error}),
    do: "Could not load this provider's model catalog:\n"

  defp overlay_message_prefix(%{kind: :codex_error}), do: "Codex App Server reported:\n"
  defp overlay_message_prefix(_overlay), do: ""

  defp model_id(%{id: id}), do: id
  defp model_id(%{"id" => id}), do: id

  defp model_context(model),
    do: Map.get(model, :context_length) || Map.get(model, "context_length")

  defp approval_label(:ask), do: "ASK"
  defp approval_label(:read_only), do: "READ"
  defp approval_label(:full_access), do: "AUTO"

  defp short(nil, _max), do: "—"

  defp short(value, max) do
    if String.length(value) <= max, do: value, else: String.slice(value, 0, max - 1) <> "…"
  end

  defp style(opts), do: struct(Style, opts)
  defp add(widgets, widget, rect), do: widgets ++ [{widget, rect}]
  defp maybe_add(widgets, _widget, nil), do: widgets
  defp maybe_add(widgets, widget, rect), do: add(widgets, widget, rect)
end
