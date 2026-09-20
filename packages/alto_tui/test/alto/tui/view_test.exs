defmodule Alto.TUI.ViewTest do
  use ExUnit.Case, async: true

  alias Alto.TUI.{State, View}
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

  test "shows the saved-key placeholder when another field is active" do
    state =
      base_state(%{
        field_index: 1,
        key_saved?: true,
        fields: provider_fields(api_key: "")
      })

    terminal = ExRatatui.init_test_terminal(120, 36)
    assert :ok = ExRatatui.draw(terminal, View.widgets(state, frame()))

    assert ExRatatui.get_buffer_content(terminal) =~
             "API key       (saved — leave blank to keep)"
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

  test "native input scrolls a long Unicode model identifier to its cursor" do
    input = ExRatatui.text_input_new()
    value = String.duplicate("界", 16) <> "END"
    :ok = ExRatatui.text_input_set_value(input, value)

    state = base_state(model_form(input))
    widgets = View.widgets(state, frame(30, 20))
    assert %TextInput{state: ^input} = active_input(widgets)

    terminal = ExRatatui.init_test_terminal(30, 20)
    assert :ok = ExRatatui.draw(terminal, widgets)
    screen = ExRatatui.get_buffer_content(terminal)
    assert screen =~ "Model ID"
    assert screen =~ "END"
  end

  test "native input reserves a cell for the cursor when the value fills the field" do
    input = ExRatatui.text_input_new()
    :ok = ExRatatui.text_input_set_value(input, "abcd")
    state = base_state(model_form(input))

    widgets = View.widgets(state, frame(30, 20))
    terminal = ExRatatui.init_test_terminal(30, 20)
    assert :ok = ExRatatui.draw(terminal, widgets)
    screen = ExRatatui.get_buffer_content(terminal)
    assert screen =~ "bcd"
    refute screen =~ "abcd"
  end

  test "model buttons retain their mouse-routing rows" do
    state = base_state(model_form(ExRatatui.text_input_new()))
    widgets = View.widgets(state, frame(80, 30))

    rects =
      for {%Paragraph{text: text}, rect} <- widgets,
          text in ["  [ Use model ]", "  [ Cancel ]"],
          into: %{},
          do: {text, rect}

    popup_y = div(30 - div(30 * 42, 100), 2)
    assert rects["  [ Use model ]"].y == popup_y + 6
    assert rects["  [ Cancel ]"].y == popup_y + 7
  end

  defp base_state(overlay) do
    %State{
      textarea: ExRatatui.textarea_new(),
      config: Alto.Test.TUI.config(provider_profiles: [], tools: []),
      run_options: [],
      catalog_opts: [],
      dimensions: {120, 36},
      rail_visible?: false,
      details_visible?: false,
      selected_backend: :alto,
      selected_model: nil,
      backend_state: %{Alto.TUI.Backends.Codex => %{account: nil}},
      focus: :composer,
      overlay:
        Map.merge(
          %{
            kind: :provider_form,
            title: "configure provider",
            field_index: 0,
            key_saved?: false,
            error: nil
          },
          overlay
        )
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
