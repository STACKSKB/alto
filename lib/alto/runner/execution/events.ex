defmodule Alto.Runner.Execution.Events do
  @moduledoc "Bounded event retention, durable projection, and conservative outcome accounting."
  alias Alto.{Event, Session}

  @fields [
    :session,
    :session_dir,
    :event_sink,
    :events_rev,
    :events_dropped,
    :max_events,
    :verdict,
    :persistence_errors
  ]
  defmodule State do
    @moduledoc "Event retention and storage capabilities, independent of a scheduler."
    defstruct [
      :session,
      :session_dir,
      :event_sink,
      :events_rev,
      :events_dropped,
      :max_events,
      :verdict,
      :persistence_errors,
      :run_id
    ]
  end

  @doc false
  def project(run),
    do: struct!(State, Map.put(Map.take(run, @fields), :run_id, run.tool_context.session_id))

  @doc false
  def merge(run, %State{} = state), do: Map.merge(run, Map.take(state, @fields))

  def record(run, %Event{domain: :durable} = event) do
    run =
      case persist_event(run, event) do
        :ok -> run
        {:error, reason} -> add_persistence_error(run, reason)
      end

    do_record(run, event)
  end

  def record(run, event), do: do_record(run, event)

  # Live signals stay in flight only; the durable log is what sessions keep.
  # Event persistence is best-effort and silent on the hot path — rare paths
  # (started/transcript/completed) warn instead.
  defp persist_event(%{session: nil}, _event), do: :ok

  defp persist_event(run, event) do
    Session.append(
      run.session,
      Session.event_record(run.run_id, event),
      session_dir_opt(run)
    )
  end

  defp do_record(run, %Event{} = event) do
    notify(run.event_sink, event)

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

  defp merge_event_verdict(run, %{type: :run_cancelled, data: %{in_flight: in_flight}})
       when not is_nil(in_flight),
       do: merge_verdict(run, :unknown)

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

  defp notify(sink, event), do: Alto.Runner.Execution.Support.notify(sink, event)
  defp session_dir_opt(run), do: [session_dir: run.session_dir]
end
