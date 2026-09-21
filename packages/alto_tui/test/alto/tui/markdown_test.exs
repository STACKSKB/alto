defmodule Alto.TUI.MarkdownTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.{Markdown, Transcript, Viewport, Selection}
  alias ExRatatui.{CellSession, Text}
  alias ExRatatui.Event.{Key, Mouse}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph

  defp plain(%Text{lines: lines}),
    do: Enum.map_join(lines, "\n", fn line -> Enum.map_join(line.spans, & &1.content) end)

  test "native Markdown styles headings, emphasis and inline code" do
    rich = Markdown.render("## Review\n\nA **confirmed** finding in `src/main.ex`.", 60)
    assert plain(rich) =~ "Review"
    assert plain(rich) =~ "A confirmed finding in src/main.ex."
    assert :bold in hd(hd(rich.lines).spans).style.modifiers

    assert Enum.any?(
             Enum.flat_map(rich.lines, & &1.spans),
             &(&1.content =~ "confirmed" and :bold in &1.style.modifiers)
           )
  end

  test "fenced code retains indentation, line breaks and wide glyphs while streaming" do
    source = "```elixir\n  def run do\n    IO.puts(\"猫\")\n  end"

    for text <- [source, source <> "\n```"], width <- [18, 60] do
      rich = Markdown.render(text, width)
      assert plain(rich) =~ "  def run do"
      assert plain(rich) =~ "    IO.puts(\"猫\")"
      refute plain(rich) =~ "```"
      assert plain(rich) =~ "  end"
    end
  end

  test "heading syntax preserves meaningful hashes and indented code remains code" do
    headings = Markdown.plain("## C#\n\nAlternate heading\n===", 40)
    assert headings =~ "C#"
    assert headings =~ "Alternate heading"
    rendered = Markdown.plain("    def run do\n      :ok\n    end", 40)
    assert rendered =~ "def run do\n  :ok\nend"
    refute rendered =~ "```"
  end

  test "a header-only table stays visible before the first streamed row arrives" do
    assert Markdown.plain("| Long heading | Another heading |\n| --- | --- |", 20) =~
             "Long heading:"
  end

  test "small tables align and large evidence tables become complete labeled records" do
    table = "| File | Verdict |\n| --- | --- |\n| `one.ex` | **OK** |\n| `two.ex` | Fix |"
    wide = Markdown.plain(table, 80)
    assert wide =~ "File"
    assert wide =~ "│"
    assert wide =~ "one.ex"
    refute wide =~ "**"
    narrow = Markdown.plain(table, 12)
    assert narrow =~ "File: one.ex"
    assert narrow =~ "Verdict: OK"
    assert narrow =~ "File: two.ex"
    evidence = String.duplicate("long evidence ", 50) <> "FINAL EVIDENCE"
    report = "| Finding | Evidence |\n| --- | --- |\n| Bug | #{evidence} |"
    output = Markdown.plain(report, 55)
    assert output =~ "Finding: Bug"
    assert output =~ "Evidence: long evidence"
    assert String.replace(output, "\n", " ") =~ "FINAL EVIDENCE"
    assert length(String.split(output, "\n")) > 10
  end

  test "table parsing keeps escaped pipes and pipes inside inline code" do
    source = "| Expression | Note |\n| --- | --- |\n| `a | b` | left\\|right |"
    rendered = Markdown.plain(source, 80)
    assert rendered =~ "a | b"
    assert rendered =~ "left|right"
  end

  test "long code and irregular table rows retain their final evidence" do
    code = "\t" <> String.duplicate("界", 180) <> " FINAL CODE"
    rendered = Markdown.plain("```text\n#{code}", 11)
    assert rendered =~ ~r/FINAL\s*CODE/
    assert length(Regex.scan(~r/界/u, rendered)) == 180
    assert rendered =~ "\n    界"
    refute rendered =~ "```"

    table = "| File | Result |\n| --- | --- |\n| one | ok | extra evidence |"
    rendered = Markdown.plain(table, 80)
    assert rendered =~ "Column 3: extra evidence"

    unicode_table = "| 名 | 値 |\n| --- | --- |\n| one | 猫猫猫 |"
    assert Markdown.plain(unicode_table, 15) =~ "値: 猫猫猫"
  end

  test "nested list indentation remains Markdown rather than becoming code" do
    rendered = Markdown.plain("- parent\n    - child", 30)
    assert rendered =~ "parent"
    assert rendered =~ "child"
    refute rendered =~ "code"
  end

  test "incomplete streamed blocks can become headings, tables and code" do
    source =
      "## Results\n\n| File | Result |\n| --- | --- |\n| `one.ex` | **OK** |\n\n```elixir\n  :ok\n```"

    for n <- [1, 3, 10, 28, 46, 65, byte_size(source)] do
      assert %Text{} = Markdown.render(binary_part(source, 0, n), 40)
    end

    assert Markdown.plain(source, 40) =~ "one.ex"
  end

  test "native block paging keeps all lines in order" do
    source = Enum.map_join(1..150, "\n", &"- Item #{&1}")
    rows = Markdown.plain(source, 40) |> String.split("\n")
    items = Enum.filter(rows, &String.contains?(&1, "Item"))
    assert length(items) == 150
    assert hd(items) =~ "Item 1"
    assert List.last(items) =~ "Item 150"
  end

  test "only assistant entries interpret Markdown and source stays unchanged" do
    entries = [
      %{kind: :user, text: "## literal **text**"},
      %{kind: :assistant, text: "## Rendered **heading**"}
    ]

    text = Transcript.render(entries, 60)
    assert plain(text) =~ "## literal **text**"
    assert plain(text) =~ "Rendered heading"
    refute plain(text) =~ "**heading**"
    assert List.last(entries).text == "## Rendered **heading**"
    assert Transcript.render(entries, 60) == text
  end

  test "large user and reasoning messages are not shortened by diagnostic limits" do
    message = String.duplicate("literal **content**\n", 500) <> "LAST LINE"

    for kind <- [:user, :reasoning] do
      assert Transcript.render([%{kind: kind, text: message}], 60) |> plain() =~ "LAST LINE"
    end

    activity =
      Transcript.render([%{kind: :activity, text: ~s({"output":"first\\nsecond"})}], 60)
      |> plain()

    assert activity =~ "first"
    assert activity =~ "second"
    refute activity =~ "\\n"
  end

  test "rich viewport equals the full native render, and copy follows visible formatted text" do
    text =
      Markdown.render(
        Enum.map_join(1..30, "\n\n", &"## Heading #{&1}\n\n**Evidence** 猫 #{&1}"),
        40
      )

    rect = %Rect{width: 40, height: 8}

    for offset <- [0, 15, Viewport.bottom(text, 40, 8)] do
      widgets = [{%Paragraph{text: text, wrap: false, scroll: {offset, 0}}, rect}]
      full = CellSession.new(40, 8)
      cropped = CellSession.new(40, 8)

      try do
        :ok = CellSession.draw(full, widgets)
        :ok = CellSession.draw(cropped, Viewport.widgets(widgets))
        assert CellSession.take_cells(full).cells == CellSession.take_cells(cropped).cells
      after
        CellSession.close(full)
        CellSession.close(cropped)
      end

      {:handled, selected} =
        Selection.event(
          Selection.new(),
          %Key{code: "a", modifiers: ["ctrl", "shift"]},
          {40, 8},
          fn -> widgets end
        )

      assert Selection.text(selected) =~ "Evidence"
      refute Selection.text(selected) =~ "**"
    end

    assert Viewport.bottom(text, 40, 8) == length(text.lines) - 8
  end

  test "the actual frame width controls reflow when resizing a report" do
    entries = [%{kind: :assistant, text: "## Report\n\n" <> String.duplicate("evidence ", 30)}]

    state = %Alto.TUI.State{
      textarea: ExRatatui.textarea_new(),
      run_options: [],
      catalog_opts: [],
      dimensions: {240, 70}
    }

    state = Alto.TUI.State.put_entries(state, nil, entries)
    widgets = Alto.TUI.View.widgets(state, %{width: 100, height: 40})

    {paragraph, rect} =
      Enum.find(widgets, fn
        {%Paragraph{text: %Text{}}, _} -> true
        _ -> false
      end)

    assert length(paragraph.text.lines) > 3

    assert Enum.all?(paragraph.text.lines, fn line ->
             line.spans |> Enum.map_join(& &1.content) |> String.length() <= rect.width - 2
           end)
  end

  test "dragging rich Markdown beyond the edge scrolls and retains copied history" do
    text = Markdown.render(Enum.map_join(1..30, "\n\n", &"## Heading #{&1}"), 40)
    rect = %Rect{width: 40, height: 8}
    widgets = fn -> [{%Paragraph{text: text, wrap: false}, rect}] end
    down = %Mouse{kind: "down", button: "left", x: 0, y: 0}

    {:handled, selected} =
      Selection.event(Selection.new(), down, {40, 8}, widgets, content: fn -> [rect] end)

    {:handled, selected} =
      Selection.event(selected, %{down | kind: "drag", x: 35, y: 7}, {40, 8}, widgets,
        content: fn -> [rect] end
      )

    assert selected.scroll.limit == length(text.lines) - 8

    selected =
      Enum.reduce(1..10, selected, fn _, selection ->
        {_, next} = Selection.autoscroll(selection, selection.scroll.token)
        next
      end)

    assert selected.scroll.offset > 0
    assert Selection.text(selected) =~ "Heading 1"
    assert Selection.text(selected) =~ "Heading 5"
  end
end
