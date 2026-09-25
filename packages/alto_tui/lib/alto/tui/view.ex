defmodule Alto.TUI.View do
  @moduledoc "ExRatatui renderer and deterministic hit targets for Alto's terminal client."

  alias Alto.TUI.Layout, as: PaneLayout
  alias Alto.TUI.{Menu, State, TextForm, WorkspaceForm}
  alias Alto.Usage
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Clear, List, Paragraph, Popup, TextInput}

  @accent {:rgb, 105, 180, 255}
  @muted {:rgb, 116, 126, 140}
  @panel {:rgb, 23, 28, 36}
  @panel_alt {:rgb, 29, 36, 46}

  @doc "Render one complete frame."
  def widgets(%State{} = state, %{width: width, height: height}) do
    state = %{state | dimensions: {width, height}}
    layout = layout(state, width, height)

    []
    |> add_rail(state, layout.rail)
    |> add(transcript_widget(state), layout.transcript)
    |> add(settings_widget(state), layout.settings)
    |> add(composer_widget(state), layout.composer)
    |> add(status_widget(state, width), layout.status)
    |> add_details(state, details_layout(state, width, height))
    |> add_overlay(state.overlay, layout.root)
  end

  def activity_widgets(state, %{width: width, height: height}) do
    case State.activity(state) do
      nil ->
        []

      {label, started} ->
        Alto.TUI.Activity.widgets(
          label,
          started,
          state.activity_tick,
          layout(state, width, height).transcript
        )
    end
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

  @doc "Content that supports ordinary selection; chrome requires Alt+drag."
  def selection_content(%State{overlay: %{kind: :workspace_form} = form}, width, height),
    do: WorkspaceForm.selection_content(form, width, height)

  def selection_content(%State{overlay: %{kind: kind} = form}, width, height)
      when kind in [:provider_form, :model_form] do
    rect = content_rect(overlay_rect(form, width, height))
    prefix = form.prefix_width

    form.fields
    |> Enum.with_index()
    |> Enum.flat_map(fn {field, row} ->
      field_row = TextForm.field_row(row)

      if ExRatatui.text_input_get_value(field.input) == "" or field_row >= rect.height,
        do: [],
        else: [
          %Rect{
            x: rect.x + prefix,
            y: rect.y + field_row,
            width: max(rect.width - prefix, 0),
            height: 1
          }
        ]
    end)
  end

  def selection_content(%State{overlay: overlay}, _, _) when not is_nil(overlay), do: []

  def selection_content(state, width, height) do
    layout = layout(state, width, height)
    details = details_layout(state, width, height)
    details_content = if details, do: [details.content], else: []

    if details && details.presentation == :drawer do
      details_content
    else
      transcript =
        if State.visible_entries(state) == [], do: [], else: [content_rect(layout.transcript)]

      composer =
        if ExRatatui.textarea_get_value(state.textarea) == "",
          do: [],
          else: [content_rect(layout.composer)]

      transcript ++ composer ++ details_content
    end
  end

  defp content_rect(rect),
    do: %Rect{
      x: rect.x + 1,
      y: rect.y + 1,
      width: max(rect.width - 2, 0),
      height: max(rect.height - 2, 0)
    }

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
    details = details_layout(state, width, height)

    cond do
      details && details.presentation == :drawer && PaneLayout.contains?(details.rect, x, y) ->
        details_target(details, x, y)

      details && details.presentation == :drawer ->
        :details_drawer_outside

      layout.left_seam && x == layout.left_seam ->
        :left_seam

      layout.right_seam && x == layout.right_seam ->
        :right_seam

      PaneLayout.contains?(layout.rail, x, y) and y == layout.rail.y + 1 ->
        :new_workspace

      PaneLayout.contains?(layout.rail, x, y) ->
        inner_height = max(layout.rail.height - 3, 0)
        selected = selected_rail_index(state, State.rail_rows(state)) || 0
        offset = max(selected - inner_height + 1, 0)
        row = y - layout.rail.y - 2

        if row >= 0 and row < inner_height do
          case Enum.at(State.rail_rows(state), row + offset) do
            %{kind: :project, id: id} when x == layout.rail.x + layout.rail.width - 2 ->
              {:close_workspace, id}

            _ ->
              {:rail_row, row + offset}
          end
        else
          :none
        end

      PaneLayout.contains?(layout.settings, x, y) ->
        settings_target(state, layout.settings, x)

      PaneLayout.contains?(layout.composer, x, y) ->
        :composer

      PaneLayout.contains?(layout.details, x, y) ->
        details_target(details, x, y)

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

  defp details_layout(state, width, height) do
    drawer = context_overlay_rect(state, width, height)
    rect = drawer || layout(state, width, height).details

    if rect do
      controls = if state.pending_approvals == [], do: [], else: approval_controls(rect)
      content = content_rect(rect)

      %{
        rect: rect,
        content: %{content | height: max(content.height - length(controls), 0)},
        controls: controls,
        presentation: if(drawer, do: :drawer, else: :pane)
      }
    end
  end

  defp add_rail(widgets, _state, nil), do: widgets

  defp add_rail(widgets, state, rect) do
    inner = %Rect{
      x: rect.x + 1,
      y: rect.y + 2,
      width: max(rect.width - 2, 0),
      height: max(rect.height - 3, 0)
    }

    widgets ++
      [
        {block(" workspaces ", state.focus == :rail), rect},
        {%Paragraph{text: "+ New workspace · ^G W", style: style(fg: @accent, bg: @panel)},
         %{inner | y: rect.y + 1, height: 1}},
        {rail_widget(state), %{inner | width: max(inner.width - 2, 0)}}
      ] ++ close_workspace_buttons(state, rect, inner)
  end

  defp close_workspace_buttons(state, rect, inner) do
    rows = State.rail_rows(state)
    offset = max((selected_rail_index(state, rows) || 0) - inner.height + 1, 0)

    rows
    |> Enum.drop(offset)
    |> Enum.take(inner.height)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{kind: :project}, row} ->
        [
          {%Paragraph{text: "×", style: style(fg: @muted, bg: @panel)},
           %Rect{x: rect.x + rect.width - 2, y: inner.y + row, width: 1, height: 1}}
        ]

      _ ->
        []
    end)
  end

  defp rail_widget(state) do
    rows = State.rail_rows(state)

    %List{
      items: Enum.map(rows, & &1.label),
      selected: selected_rail_index(state, rows),
      highlight_symbol: "› ",
      highlight_style: style(fg: @accent, bg: @panel_alt, modifiers: [:bold]),
      style: style(fg: :gray, bg: @panel),
      block: nil
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
      wrap: is_binary(text),
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

    Alto.TUI.View.Composer.widget(%{
      textarea: state.textarea,
      mode: state.composer_mode,
      focused?: state.focus == :composer,
      size: composer_inner_size(state),
      block: block(title, state.focus == :composer),
      styles: %{
        body: style(fg: :white, bg: @panel),
        muted: style(fg: @muted),
        cursor: style(fg: :black, bg: @accent),
        cursor_line: style(bg: @panel)
      }
    })
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
      " gear: B A P M R E W X T N D Q · Esc cancel "
    else
      " gear: B backend · A approval · P provider · M model · R effort · E entry · W workspace · X close workspace · T task · N new · D details · Q quit "
    end
  end

  @doc "Largest useful vertical transcript offset for the current viewport."
  def transcript_bottom_scroll(state) do
    {width, height} = state.dimensions
    transcript = layout(state, width, height).transcript
    inner_width = max(transcript.width - 2, 1)
    inner_height = max(transcript.height - 2, 1)

    Alto.TUI.Viewport.bottom(transcript_text(state), inner_width, inner_height)
  end

  defp transcript_text(state) do
    case State.visible_entries(state) do
      [] ->
        "Welcome to Alto. Start typing below.\n^G N New task · ^G W Change folder\n\n" <>
          "^G gear · B backend · A approval · P provider · M model · R effort · E entry mode · W workspace · X close workspace · T task · N new · D details · Q quit"

      entries ->
        {width, height} = state.dimensions
        rect = layout(state, width, height).transcript
        Alto.TUI.Transcript.render(entries, max(rect.width - 2, 1))
    end
  end

  defp transcript_scroll(%{transcript_follow?: true} = state),
    do: transcript_bottom_scroll(state)

  defp transcript_scroll(state),
    do: min(state.transcript_scroll, transcript_bottom_scroll(state))

  @doc "Largest useful context offset, including the approval button rows."
  def details_bottom_scroll(state) do
    {width, height} = state.dimensions
    details = details_layout(state, width, height)

    if details do
      {_, text} = details_content(state, details.presentation)
      Alto.TUI.Viewport.bottom(text, details.content.width, details.content.height)
    else
      0
    end
  end

  defp details_widget(state, details) do
    {title, text} = details_content(state, details.presentation)

    title =
      if details.presentation == :drawer,
        do: title <> "│ click header / Esc close ",
        else: title

    %Paragraph{
      text: text,
      wrap: true,
      scroll: {min(state.details_scroll, details_bottom_scroll(state)), 0},
      style: style(fg: :gray, bg: @panel),
      block: block(title, state.focus == :details)
    }
  end

  defp add_details(widgets, _state, nil), do: widgets

  defp add_details(widgets, state, layout) do
    details = details_widget(state, layout)
    clear = if layout.presentation == :drawer, do: [{%Clear{}, layout.rect}], else: []

    body =
      if layout.controls == [] do
        [{details, layout.rect}]
      else
        [
          {%{details | text: "", scroll: {0, 0}}, layout.rect},
          {%{details | block: nil}, layout.content}
        ]
      end

    buttons =
      Enum.map(layout.controls, fn control ->
        {%Paragraph{
           text: control.label,
           style: style(fg: :black, bg: @accent, modifiers: [:bold])
         }, control.rect}
      end)

    widgets ++ clear ++ body ++ buttons
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
        "  ctx #{context_consumption(state, usage)}  cache #{Float.round(Usage.last_cache_hit_rate(usage), 1)}% last / #{Float.round(Usage.cache_hit_rate(usage), 1)}% total" <>
        quota_suffix(state) <> " "

    message = if state.notice, do: " │ " <> short(state.notice, 32), else: ""
    left = left <> message
    left_width = width - String.length(right)

    text =
      if left_width > 12 and left_width >= String.length(left) do
        String.pad_trailing(left, left_width) <> right
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

  defp add_overlay(widgets, %{kind: :workspace_form} = form, root),
    do: widgets ++ WorkspaceForm.widgets(form, root)

  defp add_overlay(widgets, %{kind: kind} = form, root)
       when kind in [:provider_form, :model_form],
       do: widgets ++ text_form_widgets(form, root)

  defp add_overlay(widgets, overlay, root) do
    items = Menu.items(overlay)
    selected = safe_selected(overlay.index, items)

    list = %List{
      items: Enum.map(items, & &1.label),
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
              (items
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
      block: overlay_block(" #{Menu.title(overlay)} │ ↑↓ · Enter · Esc "),
      percent_width: 62,
      percent_height: 62
    }

    widgets ++ [{popup, root}]
  end

  defp text_form_widgets(form, root) do
    rect = overlay_rect(form, root.width, root.height)
    inner = content_rect(rect)
    bg = style(fg: :white, bg: @panel_alt)

    error_row = 2 + length(form.fields)
    {button_row, _cancel_row} = TextForm.button_rows(form)

    rows = [
      {if(form.error, do: "  ! " <> form.error, else: ""), error_row},
      {"  " <> Enum.at(form.buttons, 0), button_row},
      {"  " <> Enum.at(form.buttons, 1), button_row + 1}
    ]

    background = [
      {%Clear{}, rect},
      {%Paragraph{
         text: "  " <> form.intro,
         style: bg,
         block: overlay_block(" #{form.title} │ #{form.hint} ")
       }, rect}
    ]

    background ++
      Enum.flat_map(Enum.with_index(form.fields), &text_form_field(form, inner, bg, &1)) ++
      Enum.map(rows, fn {text, row} -> {form_paragraph(text, bg), form_row(inner, row)} end)
  end

  defp text_form_field(form, inner, bg, {field, index}) do
    active? = form.field_index == index
    locked? = Map.get(field, :locked?, false)
    secret? = Map.get(field, :secret?, false)
    prefix_width = form.prefix_width

    prefix =
      if(active?, do: "› ", else: "  ") <> String.pad_trailing(field.label, prefix_width - 2)

    row = form_row(inner, TextForm.field_row(index))
    value = ExRatatui.text_input_get_value(field.input)

    if active? and not locked? do
      visible_prefix = min(prefix_width, row.width)
      input_rect = %{row | x: row.x + visible_prefix, width: max(row.width - visible_prefix, 0)}
      state = if secret?, do: TextForm.masked_state(field), else: field.input

      [
        {form_paragraph(prefix, bg), %{row | width: min(prefix_width, row.width)}},
        {%TextInput{
           state: state,
           placeholder: Map.get(field, :placeholder),
           placeholder_style: style(fg: @muted, bg: @panel_alt),
           style: bg,
           cursor_style: style(fg: :black, bg: @accent)
         }, input_rect}
      ]
    else
      display =
        cond do
          secret? and value != "" -> String.duplicate("•", length(String.codepoints(value)))
          secret? -> Map.get(field, :placeholder, "")
          true -> value
        end

      suffix = if locked?, do: "  (fixed)", else: ""
      [{form_paragraph(prefix <> display <> suffix, bg), row}]
    end
  end

  defp form_row(inner, offset),
    do: %{inner | y: inner.y + offset, height: min(max(inner.height - offset, 0), 1)}

  defp form_paragraph(text, style), do: %Paragraph{text: text, wrap: false, style: style}

  @doc "Settings labels and exact click widths."
  def settings_segments(state) do
    profile = State.selected_profile(state)
    {width, height} = state.dimensions

    settings_width = layout(state, width, height).settings.width

    provider =
      case Alto.TUI.Backend.ui(state, :provider_label) do
        :pass -> (profile && profile.label) || "none"
        label -> label
      end

    segments =
      cond do
        settings_width < 48 ->
          [
            {:backend, " B:#{String.first(backend_label(state))} "},
            {:approval, " A:#{mini_approval_label(state)} "},
            {:entry_mode, " E:#{mini_entry_label(state)} "},
            {:details, " D:#{mini_context_label(state)} "},
            {:provider, " P:… "},
            {:model, " M:… "}
          ]

        settings_width < 112 ->
          label_width = settings_width |> Kernel.-(39) |> div(2) |> max(1) |> min(13)

          [
            {:backend, " B:#{backend_label(state)} "},
            {:approval, " A:#{approval_label(state.approval_level)} "},
            {:entry_mode, " E:#{entry_mode_label(state)} "},
            {:details, " D:#{context_label(state)} "},
            {:provider, " P:#{short(provider, label_width)} "},
            {:model, " M:#{short(state.selected_model || "choose…", label_width)} "}
          ]

        true ->
          [
            {:backend, " backend #{backend_label(state)} "},
            {:approval, " approval #{approval_label(state.approval_level)} "},
            {:details, " context #{context_label(state)} "},
            {:provider, " provider #{short(provider, 16)} "},
            {:model, " model #{short(state.selected_model || "choose…", 20)} "},
            {:entry_mode, " entry #{entry_mode_label(state)} "}
          ]
      end

    segments =
      if State.effort_choices(state) == [],
        do: segments,
        else: [{:effort, " R:#{State.selected_effort(state) || "auto"} "} | segments]

    Enum.map(segments, fn {key, text} -> %{target: {:setting, key}, text: text} end)
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

  defp details_target(%{presentation: :drawer, rect: rect}, _x, y) when y == rect.y,
    do: :details_close

  defp details_target(details, x, y) do
    Enum.find_value(details.controls, :details, fn control ->
      if PaneLayout.contains?(control.rect, x, y), do: {:approval, control.decision}
    end)
  end

  defp details_content(%{pending_approvals: [%{request: request} | _]}, _presentation) do
    {" approval required ", Alto.TUI.ApprovalView.text(request)}
  end

  defp details_content(state, _presentation) do
    recent =
      state
      |> State.visible_entries()
      |> Enum.filter(&(&1.kind in [:tool, :system, :error]))
      |> Enum.take(-12)
      |> Enum.map(&context_entry/1)
      |> Enum.join("\n\n")

    project = State.selected_project(state)
    root = if project, do: project["root"], else: ""
    {" context ", root <> "\n\n" <> recent}
  end

  defp context_entry(entry) do
    line =
      case entry do
        %{kind: :tool, text: text} -> "tool · " <> Alto.Display.result(text)
        %{kind: :error, text: text} -> "error ! " <> Alto.Display.error(text)
        %{text: text} -> "· " <> Alto.Display.text(text)
      end

    case Map.get(entry, :detail) do
      detail when detail not in [nil, "", %{}, []] -> line <> "\n" <> Alto.Display.result(detail)
      _ -> line
    end
  end

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

  defp overlay_block(title) do
    %Block{
      title: title,
      borders: [:all],
      border_type: :rounded,
      border_style: style(fg: @accent),
      style: style(bg: @panel_alt)
    }
  end

  defp popup_rect(width, height), do: popup_rect(width, height, 62, 62)

  defp overlay_rect(%{kind: :workspace_form}, width, height),
    do: WorkspaceForm.rect(width, height)

  defp overlay_rect(%{kind: kind} = form, width, height)
       when kind in [:provider_form, :model_form],
       do: popup_rect(width, height, form.width_percent, form.height_percent)

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
    case Alto.TUI.Backend.ui(state, :context_window) do
      :pass -> native_context_consumption(state, usage)
      context -> context_percent(usage, context)
    end
  end

  defp native_context_consumption(state, usage) do
    model = State.model_metadata(state) || %{}
    context_percent(usage, model[:context_length] || model["context_length"])
  end

  defp context_percent(usage, context) when is_integer(context) and context > 0 do
    percent = min(usage.last_input_tokens / context * 100.0, 999.9)
    "#{Float.round(percent, 1)}%"
  end

  defp context_percent(_usage, _context), do: "—"

  defp quota_suffix(state) do
    case Alto.TUI.Backend.ui(state, :quota_label) do
      :pass -> ""
      label -> label
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

  defp approval_label(:ask), do: "ASK"
  defp approval_label(:read_only), do: "READ"
  defp approval_label(:full_access), do: "AUTO"

  defp short(nil, _max), do: "—"

  defp short(value, max) do
    if String.length(value) <= max, do: value, else: String.slice(value, 0, max - 1) <> "…"
  end

  defp style(opts), do: struct(Style, opts)
  defp add(widgets, widget, rect), do: widgets ++ [{widget, rect}]
end
