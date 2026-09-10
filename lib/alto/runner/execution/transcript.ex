defmodule Alto.Runner.Execution.Transcript do
  @moduledoc "Bounded conversation state with optional summary, handoff, or custom compaction."
  alias Alto.{Event, Session, Usage}
  alias Alto.Context.Transcript
  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Events
  @default_compaction_summary_input_bytes 100_000
  @fields [
    :messages_rev,
    :transcript_bytes,
    :max_transcript_bytes,
    :compaction,
    :compacted?,
    :session,
    :session_dir,
    :provider,
    :provider_timeout,
    :budget,
    :cancel_ref,
    :event_sink,
    :max_steps,
    :model_requests,
    :usage
  ]
  defmodule State do
    @moduledoc "Transcript, model-compaction capabilities, and retained events."
    defstruct [
      :messages_rev,
      :transcript_bytes,
      :max_transcript_bytes,
      :compaction,
      :compacted?,
      :session,
      :session_dir,
      :provider,
      :provider_timeout,
      :budget,
      :cancel_ref,
      :event_sink,
      :max_steps,
      :model_requests,
      :usage,
      :run_id,
      :events
    ]
  end

  @doc false
  def project(run),
    do:
      struct!(
        State,
        Map.take(run, @fields)
        |> Map.put(:run_id, run.tool_context.session_id)
        |> Map.put(:events, Events.project(run))
      )

  @doc false
  def merge(run, %State{} = state),
    do: run |> Map.merge(Map.take(state, @fields)) |> Events.merge(state.events)

  def append(run, message) do
    bytes = run.transcript_bytes + byte_size(JSON.encode!(message))

    if bytes <= run.max_transcript_bytes do
      {:ok, %{run | messages_rev: [message | run.messages_rev], transcript_bytes: bytes}}
    else
      compact_transcript(run, message)
    end
  end

  # One bounded recovery rollover per run when the transcript ceiling hits.
  # The compatibility strategy summarizes the middle. The coding-harness
  # strategy produces a structured, persisted handoff. Both keep the system
  # message and a recent region verbatim, and both require a session so the
  # removed semantic facts remain durable. Any failure degrades to the
  # pre-rollover transcript error, never a retry loop.
  defp compact_transcript(%{compaction: false} = run, _message),
    do: {:error, {:transcript_limit, run.max_transcript_bytes}, run}

  defp compact_transcript(%{compacted?: true} = run, _message),
    do: {:error, {:transcript_limit, run.max_transcript_bytes}, run}

  defp compact_transcript(%{session: nil} = run, _message),
    do: {:error, :compaction_requires_session, run}

  defp compact_transcript(%{provider: nil} = run, _message),
    do: {:error, :compaction_requires_provider, run}

  defp compact_transcript(run, message) do
    case compact_middle(run) do
      {:ok, run} ->
        append(%{run | compacted?: true}, message)

      {:error, {:cancelled, _} = reason, run} ->
        {:error, reason, run}

      {:error, _reason, run} ->
        {:error, {:transcript_limit, run.max_transcript_bytes}, run}
    end
  end

  defp compact_middle(%{model_requests: count, max_steps: limit} = run) when count >= limit,
    do: {:error, {:model_step_limit, limit}, run}

  defp compact_middle(run) do
    case Keyword.fetch!(run.compaction, :strategy) do
      :summary -> summarize_middle(run)
      :handoff -> handoff_middle(run)
      {module, opts} -> custom_compaction(run, module, opts)
    end
  end

  defp custom_compaction(run, module, opts) do
    {system, middle, recent} =
      Transcript.split(
        Enum.reverse(run.messages_rev),
        Keyword.fetch!(run.compaction, :keep_recent_messages)
      )

    limit = Keyword.fetch!(run.compaction, :max_summary_bytes)
    input = render_for_summary(middle)
    {provider, provider_opts} = run.provider
    sink = fn event -> notify(run.event_sink, event) end

    outcome =
      supervised_call(
        fn ->
          with false <- middle == [],
               {:ok, request} <- module.request(input, limit, opts),
               true <-
                 is_map(request) and is_list(request[:messages]) and request[:tools] in [nil, []],
               :ok <- Budget.take_model(run.budget),
               {:ok, completion} <-
                 provider.stream(Map.put(request, :tools, []), sink, provider_opts),
               {:ok, content} <- module.decode(completion, limit, opts),
               true <-
                 is_binary(content) and content != "" and byte_size(content) <= limit and
                   String.valid?(content) do
            {:ok, content}
          else
            {:error, _} = error -> error
            _ -> {:error, :invalid_compaction_result}
          end
        end,
        Budget.timeout(run.budget, run.provider_timeout),
        run.cancel_ref
      )

    case outcome do
      {:ok, {:ok, content}} ->
        apply_summary(
          run,
          system,
          middle,
          transcript_part_bytes(middle),
          byte_size(input),
          recent,
          content,
          limit
        )

      {:cancelled, reason} ->
        {:error, {:cancelled, reason}, run}

      other ->
        record_compact_failed(run, {:custom_compaction_failed, other})
    end
  end

  defp summarize_middle(run) do
    keep = Keyword.fetch!(run.compaction, :keep_recent_messages)
    max_summary = Keyword.fetch!(run.compaction, :max_summary_bytes)
    messages = Enum.reverse(run.messages_rev)

    {system, middle, recent} = Transcript.split(messages, keep)

    if middle == [] do
      {:error, :transcript_uncompactable, run}
    else
      summarize_replacement(run, system, middle, recent, max_summary)
    end
  end

  defp handoff_middle(run) do
    keep = Keyword.fetch!(run.compaction, :keep_recent_messages)
    max_handoff = Keyword.fetch!(run.compaction, :max_handoff_bytes)
    messages = Enum.reverse(run.messages_rev)

    {system, middle, recent} = Transcript.split(messages, keep)

    if middle == [] do
      {:error, :transcript_uncompactable, run}
    else
      generate_handoff(run, system, middle, recent, max_handoff)
    end
  end

  defp generate_handoff(run, system, middle, recent, max_handoff) do
    middle_bytes = transcript_part_bytes(middle)
    input = render_for_summary(middle)
    input_bytes = byte_size(input)
    {provider, provider_opts} = run.provider
    sink = fn event -> notify(run.event_sink, event) end

    notify(
      run.event_sink,
      Event.live(:context_handoff_started, %{dropped_messages: length(middle)})
    )

    outcome =
      supervised_call(
        fn ->
          with :ok <- Budget.take_model(run.budget) do
            provider.stream(
              %{
                messages: [
                  %{"role" => "user", "content" => Alto.Handoff.prompt(input, max_handoff)}
                ],
                tools: []
              },
              sink,
              provider_opts
            )
          end
        end,
        Budget.timeout(run.budget, run.provider_timeout),
        run.cancel_ref
      )

    case outcome do
      {:ok, {:ok, %{message: message} = completion}} when is_binary(message) ->
        run = %{run | usage: Usage.merge(run.usage, Usage.normalize(Map.get(completion, :usage)))}

        with {:ok, artifact} <- Alto.Handoff.decode(message, max_handoff),
             {:ok, published} <-
               Alto.Handoff.persist(
                 run.session,
                 run.run_id,
                 artifact,
                 handoff_persist_opts(run)
               ) do
          apply_handoff(
            run,
            system,
            middle,
            middle_bytes,
            input_bytes,
            recent,
            artifact,
            published
          )
        else
          {:error, reason} -> record_compact_failed(run, reason)
        end

      {:cancelled, reason} ->
        {:error, {:cancelled, reason}, run}

      {:ok, _other} ->
        record_compact_failed(run, :handoff_response_empty)

      {:error, reason} ->
        record_compact_failed(run, {:handoff_failed, reason})
    end
  end

  defp apply_handoff(
         run,
         system,
         middle,
         middle_bytes,
         input_bytes,
         recent,
         artifact,
         published
       ) do
    rendered = Alto.Handoff.render(artifact)

    header = "[alto handoff: artifacts at #{published.directory}]"

    replacement =
      system ++ [%{"role" => "user", "content" => header <> "\n\n" <> rendered}] ++ recent

    bytes = transcript_part_bytes(replacement)

    run = %{
      run
      | messages_rev: Enum.reverse(replacement),
        transcript_bytes: bytes,
        model_requests: run.model_requests + 1
    }

    data = %{
      strategy: :handoff,
      dropped_messages: length(middle),
      dropped_bytes: middle_bytes,
      source_bytes: input_bytes,
      handoff_bytes: byte_size(rendered),
      kept_messages: length(recent),
      directory: published.directory,
      files: published.files,
      next_step: artifact.next_step
    }

    run = record_event(run, Event.durable(:context_handoff_created, data))
    run = record_event(run, Event.durable(:context_compacted, data))

    run =
      case Session.append(
             run.session,
             Session.handoff_record(Map.put(data, :run_id, run.run_id)),
             session_dir_opt(run)
           ) do
        :ok -> run
        {:error, reason} -> add_persistence_error(run, reason)
      end

    {:ok, run}
  end

  defp handoff_persist_opts(run) do
    base = session_dir_opt(run)

    case Keyword.fetch!(run.compaction, :artifact_dir) do
      nil -> base
      directory -> Keyword.put(base, :artifact_dir, directory)
    end
  end

  defp summarize_replacement(run, system, middle, recent, max_summary) do
    middle_bytes = transcript_part_bytes(middle)
    input = render_for_summary(middle)
    summarizable_bytes = byte_size(input)

    prompt =
      "Summarize this agent work transcript so the run can continue without it. " <>
        "Preserve: the active task and any plan, key decisions taken, files read or modified, " <>
        "tool outcomes the next steps depend on, errors and how they were handled, and anything " <>
        "explicitly marked unresolved. Omit pleasantries and repetition. " <>
        "Reply with plain text under #{max_summary} bytes, no tool calls."

    {provider, provider_opts} = run.provider
    sink = fn event -> notify(run.event_sink, event) end

    notify(run.event_sink, Event.live(:context_compacting, %{dropped_messages: length(middle)}))

    outcome =
      supervised_call(
        fn ->
          with :ok <- Budget.take_model(run.budget) do
            provider.stream(
              %{
                messages: [
                  %{"role" => "user", "content" => prompt <> "\n\nTranscript:\n" <> input}
                ],
                tools: []
              },
              sink,
              provider_opts
            )
          end
        end,
        Budget.timeout(run.budget, run.provider_timeout),
        run.cancel_ref
      )

    case outcome do
      {:ok, {:ok, %{message: message} = completion}} when is_binary(message) and message != "" ->
        run = %{run | usage: Usage.merge(run.usage, Usage.normalize(Map.get(completion, :usage)))}

        apply_summary(
          run,
          system,
          middle,
          middle_bytes,
          summarizable_bytes,
          recent,
          message,
          max_summary
        )

      {:cancelled, reason} ->
        {:error, {:cancelled, reason}, run}

      {:ok, _other} ->
        record_compact_failed(run, :compaction_summary_empty)

      {:error, reason} ->
        record_compact_failed(run, {:compaction_failed, reason})
    end
  end

  defp apply_summary(
         run,
         system,
         middle,
         middle_bytes,
         summarizable_bytes,
         recent,
         message,
         max_summary
       ) do
    summary = message |> binary_part(0, min(byte_size(message), max_summary)) |> trim_utf8_tail()

    header =
      "[alto compaction: summarized #{length(middle)} messages; full history in session log]"

    replacement =
      system ++ [%{"role" => "user", "content" => header <> "\n" <> summary}] ++ recent

    bytes = transcript_part_bytes(replacement)

    run = %{
      run
      | messages_rev: Enum.reverse(replacement),
        transcript_bytes: bytes,
        model_requests: run.model_requests + 1
    }

    run =
      record_event(
        run,
        Event.durable(:context_compacted, %{
          dropped_messages: length(middle),
          dropped_bytes: middle_bytes,
          summarized_bytes: summarizable_bytes,
          summary_bytes: byte_size(summary),
          kept_messages: length(recent)
        })
      )

    persisted =
      if run.session do
        Session.append(
          run.session,
          Session.compaction_record(%{
            run_id: run.run_id,
            dropped_messages: length(middle),
            dropped_bytes: middle_bytes,
            summary_bytes: byte_size(summary),
            summary: summary
          }),
          session_dir_opt(run)
        )
      end

    run =
      case persisted do
        {:error, reason} -> add_persistence_error(run, reason)
        _ -> run
      end

    {:ok, run}
  end

  defp trim_utf8_tail(text) do
    if String.valid?(text),
      do: text,
      else: trim_utf8_tail(binary_part(text, 0, byte_size(text) - 1))
  end

  defp record_compact_failed(run, reason) do
    run = record_event(run, Event.durable(:context_compact_failed, %{error: reason}))
    {:error, reason, run}
  end

  defp transcript_part_bytes(messages) do
    Enum.reduce(messages, 0, fn message, total -> total + byte_size(JSON.encode!(message)) end)
  end

  # The summarizer sees the most recent slice of the dropped middle,
  # capped in bytes and cut on a UTF-8 boundary so the prompt stays valid.
  defp render_for_summary(messages) do
    rendered =
      messages
      |> Enum.map(fn
        %{"role" => role, "content" => content} when is_binary(content) -> role <> ": " <> content
        %{"role" => role} = message -> role <> ": " <> JSON.encode!(message)
      end)
      |> Enum.join("\n")

    take_trailing_bytes(rendered, @default_compaction_summary_input_bytes)
  end

  defp take_trailing_bytes(rendered, max) do
    drop_to_valid(rendered, max(byte_size(rendered) - max, 0))
  end

  defp drop_to_valid(rendered, start) do
    tail = binary_part(rendered, start, byte_size(rendered) - start)

    if String.valid?(tail) do
      tail
    else
      drop_to_valid(rendered, start + 1)
    end
  end

  defp record_event(run, event), do: %{run | events: Events.record(run.events, event)}

  defp add_persistence_error(run, reason),
    do: %{run | events: Events.add_persistence_error(run.events, reason)}

  defp session_dir_opt(run), do: [session_dir: run.session_dir]
  defp supervised_call(fun, timeout, ref), do: Alto.Runner.Execution.Call.run(fun, timeout, ref)
  defp notify(sink, event), do: Alto.Runner.Execution.Support.notify(sink, event)
end
