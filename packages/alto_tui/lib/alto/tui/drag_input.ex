defmodule Alto.TUI.DragInput do
  @moduledoc false
  alias ExRatatui.Event.Mouse

  # Local input is synchronous. Drain only consecutive left-drag events, then
  # put the first barrier back through the app mailbox before the next poll.
  # This preserves release/copy/resize ordering without drawing stale positions.
  def poller(opts) do
    cond do
      not is_nil(opts[:test_mode]) -> nil
      Keyword.get(opts, :transport, :local) == :local -> fn -> ExRatatui.poll_event(0) end
      true -> :mailbox
    end
  end

  def latest(%Mouse{kind: "drag", button: "left"} = event, :mailbox) do
    # Inspect only the consecutive prefix; selective receive alone could skip a
    # release or keyboard event and accidentally extend a completed selection.
    {:messages, messages} = Process.info(self(), :messages)

    messages
    |> Enum.take(256)
    |> Enum.reduce_while(event, fn
      {:ex_ratatui_event, %Mouse{kind: "drag", button: "left"} = next} = message, _last ->
        receive do
          ^message -> {:cont, next}
        after
          0 -> {:halt, event}
        end

      _, last ->
        {:halt, last}
    end)
  end

  def latest(%Mouse{kind: "drag", button: "left"} = event, poll) when is_function(poll, 0),
    do: drain(event, poll, 256)

  def latest(event, _poll), do: event

  defp drain(event, _poll, 0), do: event

  defp drain(event, poll, remaining) do
    case poll.() do
      %Mouse{kind: "drag", button: "left"} = next ->
        drain(next, poll, remaining - 1)

      nil ->
        event

      {:error, _} ->
        event

      next ->
        send(self(), {:tui_deferred_input, next})
        event
    end
  end
end
