defmodule Alto.EventsTest do
  use ExUnit.Case, async: true

  test "host delivery and application observers compose in order and isolate failures" do
    owner = self()

    app =
      Alto.Events.combine([
        fn _ -> raise "broken" end,
        fn event -> send(owner, {:app, event}) end
      ])

    options = Alto.Events.attach([event_sink: app], fn event -> send(owner, {:host, event}) end)
    event = Alto.Event.live(:example)
    options[:event_sink].(event)
    assert_receive {:host, ^event}
    assert_receive {:app, ^event}
  end
end
