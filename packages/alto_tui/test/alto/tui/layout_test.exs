defmodule Alto.TUI.LayoutTest do
  use ExUnit.Case, async: true

  alias Alto.TUI.Layout

  test "collapses details before the workspace rail" do
    medium = Layout.calculate(92, 30, rail_width: 24, details_width: 36)
    assert medium.rail
    refute medium.details

    narrow = Layout.calculate(60, 24)
    refute narrow.rail
    refute narrow.details
    assert narrow.transcript.width == 60
  end
end
