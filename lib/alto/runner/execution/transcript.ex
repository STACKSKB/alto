defmodule Alto.Runner.Execution.Transcript do
  @moduledoc """
  Bounded conversation operations with optional compaction.

  Functions update the supplied map directly, so standalone callers may pass
  any map containing the fields needed by the selected operation.
  """
  alias Alto.Event
  alias Alto.Context.Transcript
  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Events
  alias Alto.Runner.Execution.Model
  alias Alto.Runner.Execution.Call
  alias Alto.Runner.Execution.Compactor

  @doc "Start one snapshot reduction without waiting for its result."
  def start_background(run) do
    if Compactor.enabled?(run) and Compactor.background?(run) and run.session != nil and
         run.compaction_count < max_compactions(run) do
      case start_reduction(run, :model_context_pressure) do
        {:ok, next} -> next
        {:error, _, next} -> next
      end
    else
      run
    end
  end

  @doc "Install a ready snapshot plus its unchanged append-only tail. Never waits for reduction."
  def poll(run) do
    if Compactor.enabled?(run) do
      case Compactor.take(run) do
        {:ready, snapshot, outcome} ->
          case settle_reduction(run, snapshot, outcome, 0) do
            {:ok, next} -> next
            {:error, _, next} -> next
          end

        _ ->
          Compactor.sync(run)
      end
    else
      run
    end
  end

  @doc "Collect ready work and cancel unfinished reduction before termination or checkpointing."
  def finish(run), do: run |> poll() |> Compactor.cancel()

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

  def reduce(run, opts), do: Compactor.scope(run, &reduce_scoped(&1, opts))

  defp reduce_scoped(run, opts) do
    required_headroom = Keyword.get(opts, :required_headroom, 0)
    reason = Keyword.get(opts, :reason, :manual)

    cond do
      required_headroom > run.max_transcript_bytes ->
        {:error, insufficient_headroom(run, run.transcript_bytes, required_headroom), run}

      run.compaction_count >= max_compactions(run) ->
        {:error, {:compaction_limit, max_compactions(run)}, run}

      true ->
        with {:ok, run} <- start_reduction(run, reason) do
          case Call.run(
                 fn -> Compactor.take(run, true) end,
                 Budget.remaining(run.budget),
                 run.cancel_ref
               ) do
            {:ready, snapshot, result} ->
              settle_reduction(run, snapshot, result, required_headroom)

            {:error, reason} ->
              {:error, reason, Compactor.cancel(run)}
          end
        end
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

      {:error, _reason, run} ->
        {:error, {:transcript_limit, run.max_transcript_bytes}, run}
    end
  end

  defp start_reduction(run, reason) do
    if Compactor.pending?(run) do
      {:ok, run}
    else
      with {:ok, input, module, opts} <- reduction_plan(run, reason) do
        Compactor.start(run, %{messages_rev: run.messages_rev, input: input}, fn ->
          reducer_outcome(Map.put(run, :compaction_model, true), input, module, opts)
        end)

        {:ok, run}
      end
    end
  end

  defp reduction_plan(run, reason) do
    {pinned, middle, recent} = reduction_parts(run)
    text = Alto.Context.Reducer.render(middle)
    limit = Keyword.fetch!(run.compaction, :max_input_bytes)

    cond do
      byte_size(text) > limit ->
        record_compact_failed(run, {:compaction_input_limit, byte_size(text), limit})

      middle == [] ->
        record_compact_failed(run, :transcript_uncompactable)

      true ->
        input = reduction_input(run, pinned, middle, recent, text, reason)

        {module, opts} = Keyword.fetch!(run.compaction, :strategy)
        {:ok, input, module, opts}
    end
  end

  defp reduction_input(run, pinned, middle, recent, text, reason) do
    count = run.compaction_count + 1
    run_id = run.session_id
    artifact_id = if count == 1, do: run_id, else: run_id <> "-context-#{count}"
    # Discarded background work may already have published its artifact.
    artifact_id =
      if Compactor.background?(run),
        do: artifact_id <> "-bg-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
        else: artifact_id

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
      artifact_id: artifact_id,
      artifact_options:
        [session_dir: run.session_dir] ++
          if(run.compaction[:artifact_dir],
            do: [artifact_dir: run.compaction[:artifact_dir]],
            else: []
          )
    }
  end

  defp reducer_outcome(run, input, module, opts) do
    Alto.Events.notify(
      run.event_sink,
      Event.live(:context_compacting, %{dropped_messages: length(input.middle)})
    )

    Call.run(
      fn ->
        {:ok, accounting} = Agent.start_link(fn -> run end)

        Call.with_server(accounting, fn accounting ->
          model = fn request ->
            try do
              request = request |> Map.put_new(:tools, []) |> Map.put(:tool_choice, :none)

              Agent.get_and_update(
                accounting,
                &Model.request(request, &1, compaction_sink(run.event_sink)),
                :infinity
              )
            catch
              :exit, _ -> {:error, :reduction_model_closed}
            end
          end

          {:compacted, module.compact(input, model, opts)}
        end)
      end,
      Budget.timeout(run.budget, run.provider_timeout),
      run.cancel_ref
    )
  end

  defp apply_outcome(run, input, {:ok, product}, headroom),
    do: apply_product(run, input, product, headroom)

  defp apply_outcome(run, _input, {:error, reason}, _headroom),
    do: record_compact_failed(run, reason)

  defp apply_outcome(run, _input, other, _headroom),
    do: record_compact_failed(run, {:compaction_failed, other})

  defp settle_reduction(run, snapshot, outcome, headroom) do
    run = Compactor.sync(run)
    tail_length = length(run.messages_rev) - length(snapshot.messages_rev)
    {tail_rev, prefix_rev} = Enum.split(run.messages_rev, max(tail_length, 0))

    if tail_length >= 0 and prefix_rev == snapshot.messages_rev and
         run.compaction_count + 1 == snapshot.input.count do
      input = %{snapshot.input | recent: snapshot.input.recent ++ Enum.reverse(tail_rev)}

      case outcome do
        {:compacted, result} -> apply_outcome(run, input, result, headroom)
        {:error, {:cancelled, _} = reason} -> {:error, reason, run}
        {:error, reason} -> record_compact_failed(run, reason)
      end
    else
      record_compact_failed(run, :compaction_snapshot_changed)
    end
  end

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
