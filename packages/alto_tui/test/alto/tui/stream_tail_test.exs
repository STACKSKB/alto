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
        assert State.current_entries(actual) == State.current_entries(expected)
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

  test "the owned live tail materializes at reads and commits on kind changes and entry updates" do
    history = for n <- 1..100, do: %{kind: :tool, text: "tool #{n}"}

    state =
      State.put_entries(%State{textarea: nil, run_options: [], catalog_opts: []}, nil, history)

    state = Enum.reduce(1..100, state, fn _, s -> State.append_assistant_delta(s, nil, "a") end)
    assert state.entries[:scratch] == history
    assert List.last(State.current_entries(state)).text == String.duplicate("a", 100)
    state = State.append_assistant_delta(state, nil, "thinking", :reasoning)

    assert Enum.map(Enum.take(State.current_entries(state), -2), & &1.kind) == [
             :assistant,
             :reasoning
           ]

    state = State.append_entry(state, nil, %{kind: :tool, text: "done"})
    assert state.stream_tails == %{}
    assert List.last(State.current_entries(state)).text == "done"
    state = State.put_entries(state, nil, [%{kind: :assistant, text: "authoritative"}])
    assert State.current_entries(state) == [%{kind: :assistant, text: "authoritative"}]
  end

  test "shortened display tails remain byte bounded and stop accumulating omitted content" do
    state =
      State.append_assistant_delta(
        %State{textarea: nil, run_options: [], catalog_opts: []},
        nil,
        String.duplicate("猫", 30_000)
      )

    shown = List.last(State.current_entries(state)).text
    assert String.valid?(shown) and byte_size(shown) <= 64_000
    assert shown =~ "display shortened"
    state = State.append_assistant_delta(state, nil, String.duplicate("next", 100_000))
    assert List.last(State.current_entries(state)).text == shown
  end
end
