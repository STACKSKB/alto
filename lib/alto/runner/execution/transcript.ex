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
    :compaction_count,
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
      :compaction_count,
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
    message_bytes = byte_size(JSON.encode!(message))
    bytes = run.transcript_bytes + message_bytes

    if bytes <= run.max_transcript_bytes do
      {:ok, %{run | messages_rev: [message | run.messages_rev], transcript_bytes: bytes}}
    else
      compact_transcript(run, message, message_bytes)
    end
  end

  @doc """
  Reduce the current context once using its configured compaction strategy.

  `:required_headroom` is the number of transcript bytes that must fit after
  the replacement. A successful pass always strictly shrinks the context and
  advances `compaction_count`; failed or ineffective passes leave both intact.
  """
  def reduce(run, opts \\ [])

  def reduce(%{compaction: false} = run, _opts),
    do: {:error, :compaction_disabled, run}

  def reduce(%{session: nil} = run, _opts),
    do: {:error, :compaction_requires_session, run}

  def reduce(run, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: reduce_with_options(run, opts),
      else: {:error, {:invalid_compaction_options, opts}, run}
  end

  def reduce(run, opts), do: {:error, {:invalid_compaction_options, opts}, run}

  defp reduce_with_options(run, opts) do
    required_headroom = Keyword.get(opts, :required_headroom, 0)
    reason = Keyword.get(opts, :reason, :manual)

    cond do
      not is_integer(required_headroom) or required_headroom < 0 ->
        {:error, {:invalid_compaction_headroom, required_headroom}, run}

      required_headroom > run.max_transcript_bytes ->
        {:error, insufficient_headroom(run, run.transcript_bytes, required_headroom), run}

      compaction_count(run) >= max_compactions(run) ->
        {:error, {:compaction_limit, max_compactions(run)}, run}

      true ->
        compact_middle(run, required_headroom, reason)
    end
  end

  # A bounded recovery rollover when the transcript ceiling hits. Both built-in
  # strategies keep the system message and a recent region verbatim and require
  # a session so removed facts remain durable. Any failure degrades to the
  # pre-rollover transcript error, never an unbounded retry loop.
  defp compact_transcript(%{compaction: false} = run, _message, _message_bytes),
    do: {:error, {:transcript_limit, run.max_transcript_bytes}, run}

  defp compact_transcript(%{session: nil} = run, _message, _message_bytes),
    do: {:error, :compaction_requires_session, run}

  defp compact_transcript(run, message, message_bytes) do
    case reduce(run, required_headroom: message_bytes, reason: :transcript_limit) do
      {:ok, run} ->
        append(run, message)

      {:error, {:cancelled, _} = reason, run} ->
        {:error, reason, run}

      {:error, :compaction_requires_provider, run} ->
        {:error, :compaction_requires_provider, run}

      {:error, _reason, run} ->
        {:error, {:transcript_limit, run.max_transcript_bytes}, run}
    end
  end

  defp compact_middle(run, required_headroom, reason) do
    case Keyword.fetch!(run.compaction, :strategy) do
      :summary -> summarize_middle(run, required_headroom, reason)
      :handoff -> handoff_middle(run, required_headroom, reason)
      {module, opts} -> custom_compaction(run, module, opts, required_headroom, reason)
    end
  end

  defp custom_compaction(run, module, opts, required_headroom, reason) do
    {system, middle, recent} =
      Transcript.split(
        Enum.reverse(run.messages_rev),
        Keyword.fetch!(run.compaction, :keep_recent_messages)
      )

    limit = Keyword.fetch!(run.compaction, :max_summary_bytes)
    input = render_for_summary(middle)

    cond do
      middle == [] ->
        {:error, :transcript_uncompactable, run}

      function_exported?(module, :reduce, 3) ->
        deterministic_compaction(
          run,
          module,
          opts,
          system,
          middle,
          recent,
          input,
          limit,
          required_headroom,
          reason
        )

      is_nil(run.provider) ->
        {:error, :compaction_requires_provider, run}

      true ->
        provider_compaction(
          run,
          module,
          opts,
          system,
          middle,
          recent,
          input,
          limit,
          required_headroom,
          reason
        )
    end
  end

  defp deterministic_compaction(
         run,
         module,
         opts,
         system,
         middle,
         recent,
         input,
         limit,
         required_headroom,
         reason
       ) do
    outcome =
      supervised_call(
        fn ->
          with {:ok, content} <- module.reduce(input, limit, opts),
               :ok <- validate_replacement(content, limit) do
            {:ok, content}
          end
        end,
        Budget.timeout(run.budget, run.provider_timeout),
        run.cancel_ref
      )

    finish_custom_compaction(
      outcome,
      run,
      system,
      middle,
      recent,
      input,
      limit,
      required_headroom,
      reason,
      0
    )
  end

  defp provider_compaction(
         run,
         module,
         opts,
         system,
         middle,
         recent,
         input,
         limit,
         required_headroom,
         reason
       ) do
    {provider, provider_opts} = run.provider
    sink = compaction_sink(run.event_sink)

    outcome =
      supervised_call(
        fn ->
          with {:ok, request} <- module.request(input, limit, opts),
               true <-
                 is_map(request) and is_list(request[:messages]) and request[:tools] in [nil, []],
               :ok <- take_compaction_model(run),
               {:ok, completion} <-
                 provider.stream(Map.put(request, :tools, []), sink, provider_opts),
               {:ok, content} <- module.decode(completion, limit, opts),
               :ok <- validate_replacement(content, limit) do
            {:ok, content, Map.get(completion, :usage)}
          else
            {:error, _} = error -> error
            _ -> {:error, :invalid_compaction_result}
          end
        end,
        Budget.timeout(run.budget, run.provider_timeout),
        run.cancel_ref
      )

    finish_custom_compaction(
      outcome,
      run,
      system,
      middle,
      recent,
      input,
      limit,
      required_headroom,
      reason,
      1
    )
  end

  defp finish_custom_compaction(
         {:ok, {:ok, content}},
         run,
         system,
         middle,
         recent,
         input,
         limit,
         required_headroom,
         reason,
         model_requests
       ) do
    apply_summary(
      run,
      system,
      middle,
      transcript_part_bytes(middle),
      byte_size(input),
      recent,
      content,
      limit,
      required_headroom,
      reason,
      model_requests
    )
  end

  defp finish_custom_compaction(
         {:ok, {:ok, content, usage}},
         run,
         system,
         middle,
         recent,
         input,
         limit,
         required_headroom,
         reason,
         model_requests
       ) do
    run = %{run | usage: Usage.merge(run.usage, Usage.normalize(usage))}

    finish_custom_compaction(
      {:ok, {:ok, content}},
      run,
      system,
      middle,
      recent,
      input,
      limit,
      required_headroom,
      reason,
      model_requests
    )
  end

  defp finish_custom_compaction(
         {:cancelled, cancel_reason},
         run,
         _system,
         _middle,
         _recent,
         _input,
         _limit,
         _headroom,
         _reason,
         _model_requests
       ),
       do: {:error, {:cancelled, cancel_reason}, run}

  defp finish_custom_compaction(
         other,
         run,
         _system,
         _middle,
         _recent,
         _input,
         _limit,
         _headroom,
         _reason,
         _model_requests
       ),
       do: record_compact_failed(run, {:custom_compaction_failed, other})

  defp summarize_middle(%{provider: nil} = run, _required_headroom, _reason),
    do: {:error, :compaction_requires_provider, run}

  defp summarize_middle(run, required_headroom, reason) do
    keep = Keyword.fetch!(run.compaction, :keep_recent_messages)
    max_summary = Keyword.fetch!(run.compaction, :max_summary_bytes)
    messages = Enum.reverse(run.messages_rev)

    {system, middle, recent} = Transcript.split(messages, keep)

    if middle == [] do
      {:error, :transcript_uncompactable, run}
    else
      summarize_replacement(
        run,
        system,
        middle,
        recent,
        max_summary,
        required_headroom,
        reason
      )
    end
  end

  defp handoff_middle(%{provider: nil} = run, _required_headroom, _reason),
    do: {:error, :compaction_requires_provider, run}

  defp handoff_middle(run, required_headroom, reason) do
    keep = Keyword.fetch!(run.compaction, :keep_recent_messages)
    max_handoff = Keyword.fetch!(run.compaction, :max_handoff_bytes)
    messages = Enum.reverse(run.messages_rev)

    {system, middle, recent} = Transcript.split(messages, keep)

    if middle == [] do
      {:error, :transcript_uncompactable, run}
    else
      generate_handoff(
        run,
        system,
        middle,
        recent,
        max_handoff,
        required_headroom,
        reason
      )
    end
  end

  defp generate_handoff(
         run,
         system,
         middle,
         recent,
         max_handoff,
         required_headroom,
         reason
       ) do
    middle_bytes = transcript_part_bytes(middle)
    input = render_for_summary(middle)
    input_bytes = byte_size(input)
    {provider, provider_opts} = run.provider
    sink = compaction_sink(run.event_sink)

    notify(
      run.event_sink,
      Event.live(:context_handoff_started, %{dropped_messages: length(middle)})
    )

    outcome =
      supervised_call(
        fn ->
          with :ok <- take_compaction_model(run) do
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
                 handoff_run_id(run),
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
            published,
            required_headroom,
            reason
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
         published,
         required_headroom,
         reason
       ) do
    rendered = Alto.Handoff.render(artifact)

    header = "[alto handoff: artifacts at #{published.directory}]"

    replacement =
      system ++ [%{"role" => "user", "content" => header <> "\n\n" <> rendered}] ++ recent

    bytes = transcript_part_bytes(replacement)

    case apply_replacement(run, replacement, bytes, required_headroom, 1) do
      {:ok, run, count} ->
        data = %{
          strategy: :handoff,
          reason: reason,
          compaction_count: count,
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
            {:error, persistence_reason} -> add_persistence_error(run, persistence_reason)
          end

        {:ok, run}

      {:error, headroom_reason} ->
        record_compact_failed(run, headroom_reason)
    end
  end

  defp handoff_run_id(run) do
    case compaction_count(run) + 1 do
      1 -> run.run_id
      count -> run.run_id <> "-context-#{count}"
    end
  end

  defp handoff_persist_opts(run) do
    base = session_dir_opt(run)

    case Keyword.fetch!(run.compaction, :artifact_dir) do
      nil -> base
      directory -> Keyword.put(base, :artifact_dir, directory)
    end
  end

  defp summarize_replacement(
         run,
         system,
         middle,
         recent,
         max_summary,
         required_headroom,
         reason
       ) do
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
    sink = compaction_sink(run.event_sink)

    notify(run.event_sink, Event.live(:context_compacting, %{dropped_messages: length(middle)}))

    outcome =
      supervised_call(
        fn ->
          with :ok <- take_compaction_model(run) do
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
          max_summary,
          required_headroom,
          reason,
          1
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
         max_summary,
         required_headroom,
         reason,
         model_requests
       ) do
    summary = message |> binary_part(0, min(byte_size(message), max_summary)) |> trim_utf8_tail()

    header =
      "[alto compaction: summarized #{length(middle)} messages; full history in session log]"

    replacement =
      system ++ [%{"role" => "user", "content" => header <> "\n" <> summary}] ++ recent

    bytes = transcript_part_bytes(replacement)

    case apply_replacement(run, replacement, bytes, required_headroom, model_requests) do
      {:ok, run, count} ->
        data = %{
          strategy: :summary,
          reason: reason,
          compaction_count: count,
          dropped_messages: length(middle),
          dropped_bytes: middle_bytes,
          summarized_bytes: summarizable_bytes,
          summary_bytes: byte_size(summary),
          kept_messages: length(recent)
        }

        run = record_event(run, Event.durable(:context_compacted, data))

        persisted =
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

        run =
          case persisted do
            {:error, persistence_reason} -> add_persistence_error(run, persistence_reason)
            _ -> run
          end

        {:ok, run}

      {:error, headroom_reason} ->
        record_compact_failed(run, headroom_reason)
    end
  end

  defp apply_replacement(run, replacement, bytes, required_headroom, model_requests) do
    cond do
      bytes >= run.transcript_bytes ->
        {:error,
         {:compaction_no_progress, %{before_bytes: run.transcript_bytes, after_bytes: bytes}}}

      bytes + required_headroom > run.max_transcript_bytes ->
        {:error, insufficient_headroom(run, bytes, required_headroom)}

      true ->
        count = compaction_count(run) + 1

        run = %{
          run
          | messages_rev: Enum.reverse(replacement),
            transcript_bytes: bytes,
            model_requests: run.model_requests + model_requests,
            compacted?: true,
            compaction_count: count
        }

        {:ok, run, count}
    end
  end

  defp insufficient_headroom(run, after_bytes, required_headroom) do
    {:compaction_insufficient_headroom,
     %{
       after_bytes: after_bytes,
       required_headroom: required_headroom,
       max_transcript_bytes: run.max_transcript_bytes
     }}
  end

  defp validate_replacement(content, limit)
       when is_binary(content) and content != "" and byte_size(content) <= limit do
    if String.valid?(content), do: :ok, else: {:error, :invalid_compaction_result}
  end

  defp validate_replacement(_content, _limit), do: {:error, :invalid_compaction_result}

  defp take_compaction_model(%{model_requests: count, max_steps: limit}) when count >= limit,
    do: {:error, {:model_step_limit, limit}}

  defp take_compaction_model(run), do: Budget.take_model(run.budget)

  defp compaction_count(run) do
    case Map.get(run, :compaction_count) do
      count when is_integer(count) and count >= 0 -> count
      _ -> if(Map.get(run, :compacted?, false), do: 1, else: 0)
    end
  end

  defp max_compactions(run), do: Keyword.get(run.compaction, :max_compactions, 1)

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
  # Internal reducer output is not an assistant answer. Keep progress observable
  # without leaking JSON artifacts (or reducer reasoning) into the conversation.
  defp compaction_sink(sink) do
    fn event ->
      notify(sink, Event.live(:context_compaction_progress, %{event: event.type}))
    end
  end

  defp notify(sink, event), do: Alto.Runner.Execution.Support.notify(sink, event)
end
