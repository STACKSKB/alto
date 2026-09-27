defmodule Alto.TUI.ViewTest do
  use ExUnit.Case, async: true

  alias Alto.TUI.{Menu, State, View}
  alias ExRatatui.Widgets.{Paragraph, TextInput}

  test "uses a native input with the saved-key placeholder" do
    input = ExRatatui.text_input_new()

    state =
      base_state(%{
        field_index: 3,
        key_saved?: true,
        fields: provider_fields(api_key: input)
      })

    widgets = View.widgets(state, frame())
    input = active_input(widgets)
    assert input.state == {"", 0, 0}
    assert input.placeholder == "(saved — leave blank to keep)"

    terminal = ExRatatui.init_test_terminal(120, 36)
    assert :ok = ExRatatui.draw(terminal, widgets)
    screen = ExRatatui.get_buffer_content(terminal)
    assert screen =~ "API key"
    assert screen =~ "(saved — leave blank to keep)"
  end

  test "shows field choices while another field is edited" do
    state =
      base_state(%{
        field_index: 1,
        key_saved?: true,
        fields: provider_fields(api_key: "")
      })

    terminal = ExRatatui.init_test_terminal(120, 36)
    assert :ok = ExRatatui.draw(terminal, View.widgets(state, frame()))

    screen = ExRatatui.get_buffer_content(terminal)
    assert screen =~ "API key"
    assert screen =~ "Name"

    assert active_input(View.widgets(state, frame())).state ==
             Menu.field(state.overlay, :label).input
  end

  test "keeps API keys masked while retaining the actual text cursor" do
    input = ExRatatui.text_input_new()
    :ok = ExRatatui.text_input_set_value(input, "secret-key")
    :ok = ExRatatui.text_input_handle_key(input, "left")

    state =
      base_state(%{
        field_index: 3,
        key_saved?: true,
        fields: provider_fields(api_key: input)
      })

    widgets = View.widgets(state, frame())
    assert %TextInput{state: {masked, 9, 0}} = active_input(widgets)
    assert masked == String.duplicate("•", 10)

    terminal = ExRatatui.init_test_terminal(120, 36)
    assert :ok = ExRatatui.draw(terminal, widgets)
    screen = ExRatatui.get_buffer_content(terminal)
    refute screen =~ "secret-key"
    assert screen =~ masked
  end

  test "keeps the insertion point visible for a long masked API key" do
    input = ExRatatui.text_input_new()
    value = String.duplicate("secret-key", 12)
    :ok = ExRatatui.text_input_set_value(input, value)
    Enum.each(1..50, fn _ -> :ok = ExRatatui.text_input_handle_key(input, "left") end)

    state =
      base_state(%{
        field_index: 3,
        key_saved?: false,
        fields: provider_fields(api_key: input)
      })

    widgets = View.widgets(state, frame(80, 30))
    assert %TextInput{state: {masked, 70, 0}} = active_input(widgets)
    assert String.length(masked) == String.length(value)

    terminal = ExRatatui.init_test_terminal(80, 30)
    assert :ok = ExRatatui.draw(terminal, widgets)
    screen = ExRatatui.get_buffer_content(terminal)
    refute screen =~ "secret-key"
    assert screen =~ String.duplicate("•", 20)
  end

  test "keeps the active run stage visible in a narrow status bar" do
    state =
      base_state(%{})
      |> Map.put(:overlay, nil)
      |> Map.put(:runs, %{run: %{task_id: nil, phase: "waiting for model"}})

    layout = View.layout(state, 80, 30)

    {status, _rect} =
      Enum.find(View.widgets(state, frame(80, 30)), fn {widget, rect} ->
        rect == layout.status and match?(%Paragraph{}, widget)
      end)

    assert status.text =~ "waiting for model"
    assert status.text =~ "Esc stop"
  end

  test "model action rows share the rendered menu geometry" do
    state = base_state(model_form(ExRatatui.text_input_new()))
    widgets = View.widgets(state, frame(80, 30))

    {%ExRatatui.Widgets.List{}, list} =
      Enum.find(widgets, fn {widget, _} -> match?(%ExRatatui.Widgets.List{}, widget) end)

    assert View.hit_target(state, 80, 30, list.x + 1, list.y + 1) == {:overlay_row, 1}
    assert View.hit_target(state, 80, 30, list.x + 1, list.y + 2) == {:overlay_row, 2}
    assert View.hit_target(state, 80, 30, list.x + 1, list.y + 3) == :overlay
  end

  test "wrapped validation errors precede the selected editor and action rows" do
    state = base_state(model_form(ExRatatui.text_input_new()))

    state =
      put_in(state.overlay.error, "First failure line\nSecond failure line\nThird failure line")

    widgets = View.widgets(state, frame(80, 30))
    terminal = ExRatatui.init_test_terminal(80, 30)
    assert :ok = ExRatatui.draw(terminal, widgets)
    screen = ExRatatui.get_buffer_content(terminal)

    for text <- ["First failure line", "Second failure line", "Third failure line"],
        do: assert(screen =~ text)

    assert active_input(widgets).state == Menu.field(state.overlay, :model).input
  end

  test "context percentage uses the selected task's usage limit" do
    state = %{base_state(%{}) | overlay: nil}

    state =
      Enum.reduce([{"first", 100_000}, {"second", 200_000}], state, fn {task, limit}, state ->
        State.put_usage(state, task, %{
          Alto.Usage.new()
          | last_input_tokens: 1_000,
            context_window: limit
        })
      end)

    for {task, expected} <- [{"first", "1.0%"}, {"second", "0.5%"}, {"restored", "—"}] do
      state = %{state | selected_task_id: task}
      layout = View.layout(state, 120, 36)

      {status, _} =
        Enum.find(View.widgets(state, frame()), fn {widget, rect} ->
          rect == layout.status and match?(%Paragraph{}, widget)
        end)

      assert status.text =~ "ctx #{expected}"
    end
  end

  defp base_state(overlay) do
    kind = Map.get(overlay, :kind, :provider_form)
    provider? = kind == :provider_form

    labels = %{
      id: "ID",
      label: "Name",
      base_url: "Base URL",
      api_key: "API key",
      model: "Model ID"
    }

    placeholder =
      if overlay[:key_saved?], do: "(saved — leave blank to keep)", else: "(not saved)"

    fields = Map.get(overlay, :fields, [])

    definitions =
      Enum.map(fields, fn field ->
        {field.key, labels[field.key], "",
         [secret?: field.key == :api_key, placeholder: if(field.key == :api_key, do: placeholder)]}
      end)

    form =
      Menu.form(kind, Map.get(overlay, :title, "configure provider"), definitions,
        on_action: fn state, _ -> state end,
        intro: "Configure",
        hint: "Enter · Esc",
        prefix_width: if(provider?, do: 16, else: 12),
        width_percent: if(provider?, do: 72, else: 62),
        height_percent: if(provider?, do: 66, else: 42),
        button_gap: if(provider?, do: 0, else: 1),
        buttons: [if(provider?, do: "[ Save provider ]", else: "[ Use model ]"), "[ Cancel ]"]
      )

    inputs = Map.new(fields, &{&1.key, &1.input})

    form = %{
      form
      | index: overlay[:field_index] || 0,
        items:
          Enum.map(form.items, fn item ->
            if item[:input], do: %{item | input: inputs[item.key]}, else: item
          end)
    }

    %State{
      textarea: ExRatatui.textarea_new(),
      run_options: [],
      catalog_opts: [],
      dimensions: {120, 36},
      rail_visible?: false,
      details_visible?: false,
      selected_backend: :alto,
      selected_model: nil,
      backend_state: %{Alto.TUI.Backends.Codex => %{account: nil}},
      focus: :composer,
      overlay: Map.merge(form, Map.drop(overlay, [:fields]))
    }
  end

  defp provider_fields(overrides) do
    values =
      Map.merge(
        %{
          id: "openrouter",
          label: "OpenRouter",
          base_url: "https://example.test/v1",
          model: "model"
        },
        Map.new(overrides)
      )

    Enum.map([:id, :label, :base_url, :api_key, :model], fn key ->
      input = Map.get(values, key, ExRatatui.text_input_new())

      if is_reference(input) do
        input
      else
        ref = ExRatatui.text_input_new()
        :ok = ExRatatui.text_input_set_value(ref, input)
        ref
      end
      |> then(&%{key: key, input: &1, locked?: false})
    end)
  end

  defp model_form(input),
    do: %{
      kind: :model_form,
      title: "exact model ID",
      fields: [%{key: :model, input: input}],
      field_index: 0,
      error: nil
    }

  defp frame(width \\ 120, height \\ 36), do: %{width: width, height: height}

  defp active_input(widgets) do
    {input, _rect} = Enum.find(widgets, fn {widget, _rect} -> match?(%TextInput{}, widget) end)
    input
  end
end
