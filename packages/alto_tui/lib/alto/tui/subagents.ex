defmodule Alto.TUI.Subagents do
  @moduledoc "Bounded per-task child activity, separate from the parent conversation."
  alias Alto.Event

  def list(state),
    do:
      state.subagents
      |> Map.get(state.selected_task_id, %{})
      |> Map.values()
      |> Enum.sort_by(& &1.agent_id)

  def ingest(state, task, %Event{
        type: :subagent_progress,
        data: %{event: %Event{type: type} = event}
      })
      when type in [:subagent_progress, :subagent_status],
      do: ingest(state, task, event)

  def ingest(state, task, %Event{type: :subagent_progress, data: data}) do
    update(state, task, data, fn agent ->
      event = data.event
      phase = Alto.TUI.Activity.phase(event.type, agent.phase)

      text =
        case event do
          %{type: :model_delta, data: %{text: text}} ->
            text

          %{type: :model_reasoning_delta, data: %{text: text}} ->
            text

          %{type: type, data: info} when type in [:tool_started, :tool_completed, :tool_failed] ->
            "\n" <> Alto.TUI.Transcript.text(Alto.ToolDisplay.entry(type, info)) <> "\n"

          %{type: :input_received, data: info} ->
            "\ninput › " <> info.text <> "\n"

          _ ->
            ""
        end

      %{agent | phase: phase, activity: tail(agent.activity <> text)}
    end)
  end

  def ingest(state, task, %Event{type: :subagent_status, data: data}) do
    update(state, task, data, fn agent ->
      result = data[:result]
      status = if result, do: to_string(result.status), else: to_string(data.status)
      output = if result && result[:output], do: Alto.Display.error(result.output), else: ""
      reason = if result && result[:reason], do: Alto.Display.error(result.reason), else: ""
      %{agent | status: status, phase: status, result: tail(output <> "\n" <> reason)}
    end)
  end

  defp update(state, task, data, fun) do
    agents = Map.get(state.subagents, task, %{})
    key = data.agent_id

    if Map.has_key?(agents, key) or map_size(agents) < 256 do
      base = %{
        agent_id: key,
        id: data.id,
        parent: data[:parent],
        model: data[:model],
        backend: data[:backend],
        status: "running",
        phase: "working",
        activity: "",
        result: ""
      }

      agent = fun.(Map.get(agents, key, base))
      %{state | subagents: Map.put(state.subagents, task, Map.put(agents, key, agent))}
    else
      state
    end
  end

  def summary(state) do
    case list(state) do
      [] -> ""
      agents -> "Subagents · ^G U view\n" <> Enum.map_join(agents, "\n", &label/1) <> "\n\n"
    end
  end

  def label(agent),
    do: "#{agent.id} · #{agent.phase} · #{agent.model || agent.backend || "inherited"}"

  def details(state) do
    case Enum.find(list(state), &(&1.agent_id == state.selected_agent_id)) do
      nil ->
        nil

      agent ->
        {" subagent #{agent.id} · ^G U agents · Esc back ",
         "#{agent.agent_id}\nParent: #{agent.parent}\n#{label(agent)}\n\n" <>
           agent.activity <> "\n\n" <> agent.result}
    end
  end

  defp tail(text) do
    # Bound retained streamed text, preserving valid UTF-8 at the cut.
    if byte_size(text) > 16_000, do: text |> String.slice(-4_000, 4_000), else: text
  end
end
