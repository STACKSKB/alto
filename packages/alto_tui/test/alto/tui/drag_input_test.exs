defmodule Alto.TUI.DragInputTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.DragInput
  alias ExRatatui.Event.{Key, Mouse, Resize}

  test "local drag bursts collapse to the newest position without crossing release, copy or resize" do
    first = %Mouse{kind: "drag", button: "left", x: 1, y: 1}
    latest = %{first | x: 200, y: 60}

    for barrier <- [
          %{first | kind: "up"},
          %Key{code: "c", modifiers: ["ctrl"]},
          %Resize{width: 80, height: 24}
        ] do
      Process.put(:input, [first, latest, barrier, %{first | x: 0}])
      assert DragInput.latest(first, &poll/0) == latest
      assert_receive {:tui_deferred_input, ^barrier}
      assert poll().x == 0
    end
  end

  test "draining is bounded and test or remote clients do not read the local terminal" do
    first = %Mouse{kind: "drag", button: "left", x: 1, y: 1}
    Process.put(:input, List.duplicate(first, 300))
    assert DragInput.latest(first, &poll/0) == first
    assert length(Process.get(:input)) == 44
    assert DragInput.poller(test_mode: {80, 24}) == nil
    assert DragInput.poller(transport: :session) == :mailbox
    assert DragInput.poller(transport: :cell_session) == :mailbox
    assert is_function(DragInput.poller([]), 0)
    assert DragInput.latest(first, nil) == first
  end

  test "remote motion coalesces only the mailbox prefix and preserves every barrier" do
    first = %Mouse{kind: "drag", button: "left", x: 1, y: 1}
    latest = %{first | x: 140, y: 40}
    release = %{first | kind: "up"}
    send(self(), {:ex_ratatui_event, first})
    send(self(), {:ex_ratatui_event, latest})
    send(self(), {:ex_ratatui_event, release})
    send(self(), {:ex_ratatui_event, first})
    assert DragInput.latest(first, :mailbox) == latest
    assert_receive {:ex_ratatui_event, ^release}
    assert_receive {:ex_ratatui_event, ^first}
    send(self(), :background_message)
    send(self(), {:ex_ratatui_event, latest})
    assert DragInput.latest(first, :mailbox) == first
    assert_receive :background_message
    assert_receive {:ex_ratatui_event, ^latest}
  end

  defp poll do
    case Process.get(:input, []) do
      [head | tail] ->
        Process.put(:input, tail)
        head

      [] ->
        nil
    end
  end
end
