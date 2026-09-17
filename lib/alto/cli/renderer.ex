defmodule Alto.CLI.Renderer do
  @moduledoc "Owns ordered stdio event rendering and final-output suppression after streaming."
  alias Alto.Event

  def start(status?), do: spawn(fn -> render_loop(false, status?) end)

  defp render_loop(streamed?, status?) do
    receive do
      {:event, event} ->
        render_loop(render_event(event, status?) or streamed?, status?)

      {:stop, caller, reference} ->
        send(caller, {:renderer_stopped, reference, streamed?})
    end
  end

  def stop(renderer) do
    reference = make_ref()
    monitor = Process.monitor(renderer)
    send(renderer, {:stop, self(), reference})

    receive do
      {:renderer_stopped, ^reference, streamed?} ->
        Process.demonitor(monitor, [:flush])
        streamed?

      {:DOWN, ^monitor, :process, ^renderer, _reason} ->
        false
    after
      1_000 ->
        Process.demonitor(monitor, [:flush])
        false
    end
  end

  defp render_event(%Event{domain: :live, type: :model_delta, data: %{text: text}}, _status?) do
    IO.write(text)
    true
  end

  defp render_event(
         %Event{domain: :live, type: :model_started, data: %{step: step}},
         true
       ) do
    IO.puts(:stderr, "[model: request #{step}]")
    false
  end

  defp render_event(%Event{domain: :live, type: :tool_started, data: %{name: name}}, _status?) do
    IO.puts(:stderr, "\n[tool: #{name}]")
    false
  end

  defp render_event(_event, _status?), do: false

  def finish(output, streamed?) when is_binary(output) and output != "" do
    if not streamed?, do: IO.write(output)
  end

  def finish(_output, _state), do: :ok
end
