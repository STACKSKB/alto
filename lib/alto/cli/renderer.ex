defmodule Alto.CLI.Renderer do
  @moduledoc "Owns ordered stdio event rendering and final-output suppression after streaming."
  use GenServer
  alias Alto.Event

  def start(status?) do
    {:ok, pid} = GenServer.start(__MODULE__, status?)
    pid
  end

  def stop(renderer) do
    GenServer.call(renderer, :stop, 1_000)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(status?), do: {:ok, {false, status?}}

  @impl true
  def handle_info({:event, event}, {streamed?, status?}),
    do: {:noreply, {render_event(event, status?) or streamed?, status?}}

  @impl true
  def handle_call(:stop, _from, {streamed?, _} = state) do
    {:stop, :normal, streamed?, state}
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
