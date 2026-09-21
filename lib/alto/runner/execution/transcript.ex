defmodule Alto.Runner.Execution.Transcript do
  @moduledoc """
  Bounded conversation operations with optional compaction.

  Functions update the supplied map directly, so standalone callers may pass
  any map containing the fields needed by the selected operation.
  """
  alias Alto.{Event, Usage}
  alias Alto.Context.Transcript
  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Events

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

      run.compaction_count >= max_compactions(run) ->
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
    {pinned, middle, recent} = reduction_parts(run)
    text = Alto.Context.Reducer.render(middle)
    limit = Keyword.fetch!(run.compaction, :max_input_bytes)

    cond do
      byte_size(text) > limit ->
        record_compact_failed(run, {:compaction_input_limit, byte_size(text), limit})

      middle == [] ->
        {:error, :transcript_uncompactable, run}

      true ->
        input = reduction_input(run, pinned, middle, recent, text, reason)

        {module, opts} = Keyword.fetch!(run.compaction, :strategy)
        execute_reducer(run, input, module, opts, required_headroom)
    end
  end

  defp reduction_input(run, pinned, middle, recent, text, reason) do
    count = run.compaction_count + 1
    run_id = run.tool_context.session_id

    %{
      pinned: pinned,
      middle: middle,
      recent: recent,
      text: text,
      middle_bytes: Transcript.bytes(middle),
      tools: reduction_tools(run),
      request_mode: run.compaction[:request_mode],
      max_summary_bytes: run.compaction[:max_summary_bytes],
      max_handoff_bytes: run.compaction[:max_handoff_bytes],
      session: run.session,
      run_id: run_id,
      reason: reason,
      count: count,
      artifact_id: if(count == 1, do: run_id, else: run_id <> "-context-#{count}"),
      artifact_options:
        [session_dir: run.session_dir] ++
          if(run.compaction[:artifact_dir],
            do: [artifact_dir: run.compaction[:artifact_dir]],
            else: []
          )
    }
  end

  defp execute_reducer(run, input, module, opts, headroom) do
    Alto.Events.notify(
      run.event_sink,
      Event.live(:context_compacting, %{dropped_messages: length(input.middle)})
    )

    outcome =
      Alto.Runner.Execution.Call.run(
        fn ->
          {:ok, accounting} = Agent.start_link(fn -> {0, Usage.new()} end)

          try do
            model = fn request ->
              try do
                Agent.get_and_update(accounting, &reduction_model(run, request, &1), :infinity)
              catch
                :exit, _ -> {:error, :reduction_model_closed}
              end
            end

            result = module.compact(input, model, opts)
            {result, Agent.get(accounting, & &1, :infinity)}
          after
            if Process.alive?(accounting), do: Agent.stop(accounting)
          end
        end,
        Budget.timeout(run.budget, run.provider_timeout),
        run.cancel_ref
      )

    case outcome do
      {:ok, {result, {requests, usage}}} ->
        run = %{
          run
          | usage: Usage.merge(run.usage, usage),
            model_requests: run.model_requests + requests
        }

        case result do
          {:ok, product} -> apply_product(run, input, product, headroom)
          {:error, reason} -> record_compact_failed(run, reason)
          other -> record_compact_failed(run, {:compaction_failed, other})
        end

      {:cancelled, reason} ->
        {:error, {:cancelled, reason}, run}

      other ->
        record_compact_failed(run, {:compaction_failed, other})
    end
  end

  defp reduction_model(%{provider: nil}, _request, accounting),
    do: {{:error, :compaction_requires_provider}, accounting}

  defp reduction_model(run, request, {count, usage} = accounting) when is_map(request) do
    {provider, opts} = run.provider

    with true <- is_list(request[:messages]) and is_list(Map.get(request, :tools, [])),
         :ok <- take_compaction_model(%{run | model_requests: run.model_requests + count}) do
      request = request |> Map.put_new(:tools, []) |> Map.put(:tool_choice, :none)

      case provider.stream(request, compaction_sink(run.event_sink), opts) do
        {:ok, completion} = result when is_map(completion) ->
          {result, {count + 1, Usage.merge(usage, Usage.normalize(completion[:usage]))}}

        other ->
          {other, {count + 1, usage}}
      end
    else
      false -> {{:error, :invalid_compaction_request}, accounting}
      {:error, _} = error -> {error, accounting}
    end
  end

  defp reduction_model(_run, _request, accounting),
    do: {{:error, :invalid_compaction_request}, accounting}

  defp apply_product(
         run,
         input,
         %{content: content, data: data} = product,
         headroom
       )
       when is_binary(content) and content != "" and is_map(data) do
    replacement = input.pinned ++ [%{"role" => "user", "content" => content}] ++ input.recent

    with true <- String.valid?(content),
         true <- valid_product_size?(product, run.compaction[:max_input_bytes]),
         {:ok, run, count} <-
           apply_replacement(
             run,
             replacement,
             Transcript.bytes(replacement),
             headroom
           ) do
      data =
        Map.merge(data, %{
          reason: input.reason,
          compaction_count: count,
          dropped_messages: length(input.middle),
          dropped_bytes: input.middle_bytes,
          kept_messages: length(input.recent)
        })

      {:ok, Events.record(run, Event.durable(:context_compacted, data))}
    else
      false -> record_compact_failed(run, :invalid_compaction_result)
      {:error, reason} -> record_compact_failed(run, reason)
    end
  end

  defp apply_product(run, _input, _product, _headroom),
    do: record_compact_failed(run, :invalid_compaction_result)

  defp valid_product_size?(product, limit) do
    byte_size(JSON.encode!(product)) <= limit
  rescue
    _ -> false
  end

  defp apply_replacement(run, replacement, bytes, required_headroom) do
    cond do
      bytes >= run.transcript_bytes ->
        {:error,
         {:compaction_no_progress, %{before_bytes: run.transcript_bytes, after_bytes: bytes}}}

      bytes + required_headroom > run.max_transcript_bytes ->
        {:error, insufficient_headroom(run, bytes, required_headroom)}

      true ->
        count = run.compaction_count + 1

        run = %{
          run
          | messages_rev: Enum.reverse(replacement),
            transcript_bytes: bytes,
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

  defp take_compaction_model(%{model_requests: count, max_steps: limit}) when count >= limit,
    do: {:error, {:model_step_limit, limit}}

  defp take_compaction_model(run), do: Budget.take_model(run.budget)

  defp max_compactions(run), do: Keyword.get(run.compaction, :max_compactions, 1)

  defp record_compact_failed(run, reason) do
    run = Events.record(run, Event.durable(:context_compact_failed, %{error: reason}))
    {:error, reason, run}
  end

  defp reduction_parts(run) do
    Transcript.split(
      Enum.reverse(run.messages_rev),
      Keyword.fetch!(run.compaction, :keep_recent_messages),
      Keyword.get(run.compaction, :keep_initial_messages, 0)
    )
  end

  defp reduction_tools(run) do
    if Keyword.get(run.compaction, :request_mode, :transcript) == :transcript do
      exposure = Map.get(run, :request_model_tools) || Map.get(run, :model_tools)

      Enum.filter(Map.get(run, :tool_definitions) || [], fn tool ->
        is_nil(exposure) or MapSet.member?(exposure, tool["function"]["name"])
      end)
    else
      []
    end
  end

  # Internal reducer output is not an assistant answer. Keep progress observable
  # without leaking JSON artifacts (or reducer reasoning) into the conversation.
  defp compaction_sink(sink) do
    fn event ->
      Alto.Events.notify(sink, Event.live(:context_compaction_progress, %{event: event.type}))
    end
  end
end
