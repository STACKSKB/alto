defmodule Alto.TUI.LayoutTest do
  use ExUnit.Case, async: true

  alias Alto.TUI.Layout

  test "keeps rail, transcript, composer, and one-row telemetry at desktop widths" do
    layout = Layout.calculate(150, 42, rail_width: 28)

    assert layout.rail.width == 28
    refute layout.details
    assert layout.transcript.width == 122
    assert layout.settings.height == 1
    assert layout.composer.height == 6
    assert layout.status.height == 1
    assert layout.status.y == 41
  end

  test "collapses the workspace rail on narrow terminals" do
    medium = Layout.calculate(92, 30, rail_width: 24)
    assert medium.rail
    refute medium.details

    narrow = Layout.calculate(60, 24)
    refute narrow.rail
    refute narrow.details
    assert narrow.transcript.width == 60
  end
end
