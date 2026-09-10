defmodule Alto.TUI.ViewTest do
  use ExUnit.Case, async: true

  alias Alto.TUI.{State, View}
  alias ExRatatui.Widgets.{Paragraph, Popup}

  test "shows a caret before the API key placeholder when the empty field is focused" do
    input = ExRatatui.text_input_new()

    state =
      base_state(%{
        field_index: 3,
        key_saved?: true,
        fields: provider_fields(api_key: input)
      })

    line = provider_popup_line(View.widgets(state, frame()), 5)
    rendered = line_text(line)
    caret = match_index(rendered, "▏")

    assert rendered =~ "API key"
    assert rendered =~ "(saved — leave blank to keep)"
    assert caret > match_index(rendered, "API key")
    assert caret < match_index(rendered, "(saved")
    assert Enum.any?(line.spans, &(&1.content == "▏"))

    terminal = ExRatatui.init_test_terminal(120, 36)
    assert :ok = ExRatatui.draw(terminal, View.widgets(state, frame()))
    assert ExRatatui.get_buffer_content(terminal) =~ "▏"
  end

  test "keeps API keys masked while placing the caret at the actual text cursor" do
    input = ExRatatui.text_input_new()
    :ok = ExRatatui.text_input_set_value(input, "secret-key")
    :ok = ExRatatui.text_input_handle_key(input, "left")

    state =
      base_state(%{
        field_index: 3,
        key_saved?: true,
        fields: provider_fields(api_key: input)
      })

    line = provider_popup_line(View.widgets(state, frame()), 5)
    rendered = line_text(line)

    refute rendered =~ "secret-key"
    assert rendered =~ "••••"
    assert Enum.count(String.graphemes(rendered), &(&1 == "•")) == 10
    assert rendered =~ "▏"
    assert Enum.any?(line.spans, &(&1.content == "▏"))
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

    rendered = line_text(provider_popup_line(View.widgets(state, frame(80, 30)), 5))

    refute rendered =~ "secret-key"
    assert rendered =~ "▏"
    assert String.starts_with?(rendered, "› API key       …")
    assert String.ends_with?(rendered, "…")
    assert Enum.count(String.graphemes(rendered), &(&1 == "•")) == 36
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

  test "keeps the caret visible at the end of a long model identifier" do
    input = ExRatatui.text_input_new()
    value = String.duplicate("model/", 16)
    :ok = ExRatatui.text_input_set_value(input, value)

    state = base_state(%{kind: :model_form, title: "exact model ID", input: input, error: nil})
    popup = popup(View.widgets(state, frame(30, 20)))
    lines = popup.content.text.lines
    line = Enum.at(lines, 2)
    rendered = line_text(line)

    assert rendered =~ "…"
    assert rendered =~ "▏"
    assert String.ends_with?(rendered, "▏")
    assert match_index(rendered, "▏") > match_index(rendered, "Model ID")

    assert rendered |> String.split("› Model ID  ", parts: 2) |> List.last() |> String.length() <=
             5

    assert Enum.any?(line.spans, &(&1.content == "▏"))
  end

  test "reserves a cell for the caret when a model value exactly fills the field" do
    input = ExRatatui.text_input_new()
    :ok = ExRatatui.text_input_set_value(input, "abcd")
    state = base_state(%{kind: :model_form, title: "exact model ID", input: input, error: nil})

    rendered =
      View.widgets(state, frame(30, 20))
      |> popup()
      |> Map.fetch!(:content)
      |> Map.fetch!(:text)
      |> Map.fetch!(:lines)
      |> Enum.at(2)
      |> line_text()

    assert String.length(rendered) <= 16
    assert String.ends_with?(rendered, "▏")

    terminal = ExRatatui.init_test_terminal(30, 20)
    assert :ok = ExRatatui.draw(terminal, View.widgets(state, frame(30, 20)))
    assert ExRatatui.get_buffer_content(terminal) =~ "▏"
  end

  defp base_state(overlay) do
    %State{
      textarea: ExRatatui.textarea_new(),
      config: Alto.Config.new(provider_profiles: [], tools: []),
      run_options: [],
      catalog_opts: [],
      dimensions: {120, 36},
      rail_visible?: false,
      details_visible?: false,
      selected_backend: :alto,
      selected_model: nil,
      codex: %{account: nil},
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

  defp frame(width \\ 120, height \\ 36), do: %{width: width, height: height}

  defp popup(widgets) do
    {popup, _rect} = Enum.find(widgets, fn {widget, _rect} -> match?(%Popup{}, widget) end)
    popup
  end

  defp provider_popup_line(widgets, index),
    do: popup(widgets).content.text.lines |> Enum.at(index)

  defp line_text(line), do: Enum.map_join(line.spans, & &1.content)

  defp match_index(string, pattern) do
    {index, _length} = :binary.match(string, pattern)
    index
  end
end
