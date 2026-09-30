defmodule Alto.TUI.TranscriptLiteralIndexTest do
  use ExUnit.Case, async: true

  alias Alto.TUI.Cache
  alias Alto.TUI.Transcript
  alias ExRatatui.Text.Line

  test "literal windows and plain groups preserve full rendered lines" do
    entries = [
      %{kind: :user, text: "first  line\n猫 and **literal**\n"},
      %{kind: :tool, text: "done", detail: "detail one\ndetail two"},
      %{kind: :activity, text: ~s({"output":"one\\ntwo"})},
      %{kind: :error, text: "failed\nagain"},
      %{kind: :assistant, text: "**styled** `answer`"},
      %{kind: "reasoning", text: "**string role** `thought`"},
      %{kind: ~c"assistant", text: "**charlist role**"},
      %{kind: :user, text: "final"}
    ]

    for width <- [4, 13, 40], opts <- [[], [expanded: true]] do
      full = Transcript.document(entries, width, "alto", opts).text.lines
      index = Transcript.index(entries, width, opts)

      assert index.rows == length(full)

      plain_lines =
        index
        |> Transcript.plain_groups()
        |> Enum.intersperse([Line.new([])])
        |> List.flatten()

      assert Enum.map(plain_lines, &line_text/1) == Enum.map(full, &line_text/1)

      for offset <- [0, 1, 3, div(index.rows, 2), max(index.rows - 2, 0)],
          height <- [1, 7, 30] do
        assert Transcript.window(index, offset, height) == Enum.slice(full, offset, height)
      end
    end
  end

  test "compact literal index fits the default cache budget" do
    Cache.clear()
    Cache.configure(16_000_000)

    entries =
      for n <- 1..200 do
        %{kind: :user, text: "#{n}\n" <> String.duplicate("row\n", 98)}
      end

    index = Transcript.index(entries, 4)

    assert Enum.any?(Cache.stats().items, fn {{namespace, _}, item} ->
             namespace == {Transcript, :indexes} and item.value == index
           end)

    assert Transcript.window(index, index.rows - 3, 3) ==
             Enum.slice(Transcript.render(entries, 4).lines, -3, 3)
  end

  test "streaming reuses unchanged plans after parallel indexing and preserves absolute rows" do
    entries =
      for n <- 1..40 do
        %{kind: :assistant, text: "## Message #{n}\n\n**Answer** 猫\n\n```elixir\n  :ok\n```"}
      end

    initial = Transcript.index(entries, 30)
    # The initial worker caches have exited. Reuse must come from the budgeted
    # transcript index, even without any Markdown cache in this process.
    Cache.drop_namespace(Alto.TUI.Markdown)

    for text <- ["streamed **reply", "streamed **reply**\n\n```elixir\n:ok"] do
      updated = entries ++ [%{kind: :assistant, text: text}]
      index = Transcript.index(updated, 30)

      for {{_, before, _, _}, {_, after_plan, _, _}} <- Enum.zip(initial.parts, index.parts) do
        assert :erts_debug.same(before, after_plan)
      end

      full = Transcript.render(updated, 30).lines
      assert index.rows == length(full)
      assert Transcript.window(index, index.rows - 8, 8) == Enum.take(full, -8)
    end

    resized = Transcript.index(entries, 12)

    assert Transcript.window(resized, 0, 15) ==
             Enum.take(Transcript.render(entries, 12).lines, 15)

    Cache.configure(0)
    assert Transcript.index(entries, 30) == initial
    assert Cache.stats().bytes == 0
  end

  defp line_text(line), do: Enum.map_join(line.spans, & &1.content) |> String.trim_trailing()
end
