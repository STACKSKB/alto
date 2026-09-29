defmodule Alto.TUI.StreamTailTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.State

  test "incremental tail matches full rebounding through entry and byte limits" do
    for detail <- ["small", String.duplicate("x", 25_000)] do
      initial =
        State.put_entries(
          %State{textarea: ExRatatui.textarea_new(), run_options: [], catalog_opts: []},
          nil,
          for(n <- 1..2000, do: %{kind: :tool, text: "#{n}", detail: detail})
        )

      Enum.reduce(1..30, initial, fn n, state ->
        kind = if rem(n, 5) == 0, do: :reasoning, else: :assistant
        text = String.duplicate("猫 ", 1000)
        entries = State.current_entries(state)

        expected =
          case List.pop_at(entries, -1) do
            {%{kind: ^kind} = last, prefix} -> prefix ++ [%{last | text: last.text <> text}]
            _ -> entries ++ [%{kind: kind, text: text}]
          end

        expected = State.put_entries(state, nil, expected)
        actual = State.append_assistant_delta(state, nil, text, kind)
        assert actual.entries == expected.entries
        actual
      end)
    end
  end

  test "replacing entries invalidates the streaming tail" do
    state =
      State.append_assistant_delta(
        %State{textarea: ExRatatui.textarea_new(), run_options: [], catalog_opts: []},
        nil,
        "old"
      )

    state = State.put_entries(state, nil, [%{kind: :user, text: "new request"}])
    state = State.append_assistant_delta(state, nil, "new answer")
    assert [%{text: "new request"}, %{text: "new answer"}] = State.current_entries(state)
  end
end
