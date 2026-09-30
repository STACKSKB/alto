defmodule Alto.TUI.Subagents do
  @moduledoc "Bounded per-task child activity, separate from the parent conversation."
  alias Alto.Event

  @doc "Rebuild bounded child activity from durable sessions without requiring resumability."
  def load(session_id, opts) do
    opts = Keyword.take(opts, [:session_dir])

    case Alto.Session.Children.list(session_id, opts) do
      {:ok, %{sessions: children, truncated: truncated}} ->
        {agents, warnings} =
          Enum.reduce([%{id: session_id} | children], {%{}, []}, fn child, {agents, warnings} ->
            case Alto.TUI.SavedSession.load(child.id, opts) do
              {:ok, projection} ->
                combined = Map.merge(agents, projection.agents)
                truncated = projection.truncated or map_size(combined) > 256
                kept = combined |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(256) |> Map.new()

                {kept,
                 if(truncated,
                   do: ["Saved child history was truncated" | warnings],
                   else: warnings
                 )}

              {:error, _} ->
                {agents, ["Some saved child activity could not be read" | warnings]}
            end
          end)

        {agents,
         if(truncated, do: ["Saved child history was truncated" | warnings], else: warnings)}

      {:error, _} ->
        {%{}, ["Saved child history could not be discovered"]}
    end
  end

  def saved_agent(session, start, records) do
    run_id = start["run_id"]
    completed = Enum.find(Enum.reverse(records), &(&1["type"] == "completed"))
    identity = if is_map(start["agent_identity"]), do: start["agent_identity"], else: %{}
    path = identity["path"]
    label = if is_list(path) and Enum.all?(path, &is_binary/1), do: Enum.join(path, "/"), else: ""
    status = if completed, do: completed["status"], else: "unknown"

    result =
      if completed,
        do: saved_value(completed["output"]) <> "\n" <> saved_value(completed["reason"]),
        else:
          "No saved completion. Another process may still be running, or may have stopped before recording its result."

    activity = Enum.reduce(records, "", fn record, acc -> tail(acc <> saved_activity(record)) end)

    %{
      agent_id: start["agent_id"] || session <> ":" <> to_string(run_id),
      id: if(label == "", do: start["task"] || "child", else: label),
      parent: start["parent_session_id"],
      session_id: session,
      model: start["model"],
      backend: start["provider"],
      status: status,
      phase: if(completed, do: status, else: "no saved completion"),
      activity: activity,
      result: tail(result)
    }
  end

  def saved_value(nil), do: ""

  def saved_value(encoded) do
    case Alto.Session.decode_term(encoded) do
      {:ok, value} -> Alto.Display.error(value)
      _ -> "[saved value unavailable]"
    end
  end

  def saved_activity(%{"type" => "event", "event" => event} = record) do
    data =
      case Alto.Session.event_data(record) do
        {:ok, data} when is_map(data) -> data
        _ -> %{}
      end

    value = if is_map(data["value"]), do: data["value"], else: %{}
    output = text_value(value["output"]) |> String.slice(-4_000, 4_000)

    case event do
      "model_completed" ->
        text_value(data["message"]) <> "\n"

      type when type in ["tool_started", "tool_completed", "tool_failed"] ->
        "\n" <>
          type <>
          " › " <>
          text_value(data["summary"] || data["name"]) <>
          if(type == "tool_failed", do: " " <> inspect(data["error"], limit: 10), else: "") <>
          "\n" <> output <> "\n"

      _ ->
        ""
    end
  end

  def saved_activity(_), do: ""
  defp text_value(value) when is_binary(value), do: value
  defp text_value(_), do: ""

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
      phase = Alto.TUI.Activity.phase(event, agent.phase)

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

      %{
        agent
        | status: status,
          phase: status,
          result: tail(output <> "\n" <> reason),
          session_id: (result && result[:session_id]) || agent.session_id
      }
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
        session_id: nil,
        status: "running",
        phase: "working",
        activity: "",
        result: ""
      }

      agent = fun.(Map.get(agents, key, base))
      Alto.TUI.State.put_agent(state, task, key, agent)
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
         "#{agent.agent_id}\nParent: #{agent.parent}\nSession: #{agent[:session_id] || "live"}\n#{label(agent)}\n\n" <>
           agent.activity <> "\n\n" <> agent.result}
    end
  end

  def tail(text) do
    # Bound retained streamed text, preserving valid UTF-8 at the cut.
    if(byte_size(text) > 16_000, do: text |> String.slice(-4_000, 4_000), else: text)
    |> Alto.Retained.detach()
  end
end
