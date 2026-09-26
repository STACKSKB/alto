defmodule Alto.Runner.Execution.Events do
  @moduledoc """
  Bounded event retention, durable persistence, and outcome accounting.

  Operations update the supplied map directly. Durable events require its
  session, session directory, and tool context; live events need only the
  retention and sink fields.
  """
  alias Alto.{Event, Session}

  def record(run, %Event{domain: :durable} = event) do
    errors =
      Alto.Runner.Execution.Session.append(run, nil, fn ->
        Session.event_record(run.tool_context.session_id, event)
      end)

    run = Enum.reduce(errors, run, &add_persistence_error(&2, &1))
    do_record(run, event)
  end

  def record(run, event), do: do_record(run, event)

  defp do_record(run, %Event{} = event) do
    Alto.Events.notify(run.event_sink, event)

    run = merge_event_verdict(run, event)

    events_rev = [event | run.events_rev]

    if length(events_rev) > run.max_events do
      %{
        run
        | events_rev: List.delete_at(events_rev, -1),
          events_dropped: run.events_dropped + 1
      }
    else
      %{run | events_rev: events_rev}
    end
  end

  defp merge_event_verdict(run, %{type: type, data: data})
       when type in [:tool_completed, :tool_failed] do
    merge_verdict(run, Map.get(data, :outcome, :empty))
  end

  defp merge_event_verdict(run, _event), do: run

  def add_persistence_error(run, reason) do
    Map.update(run, :persistence_errors, [reason], &[reason | &1])
  end

  def merge_verdict(run, class) do
    Map.put(run, :verdict, worse_verdict(Map.get(run, :verdict, :empty), class))
  end

  defp worse_verdict(left, right) do
    severity = %{
      empty: 0,
      completed: 1,
      rejected_before_dispatch: 2,
      failed_known: 3,
      unknown: 4
    }

    if Map.get(severity, right, 0) > Map.get(severity, left, 0), do: right, else: left
  end
end
