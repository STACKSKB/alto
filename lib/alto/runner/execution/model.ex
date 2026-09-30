defmodule Alto.Runner.Execution.Model do
  @moduledoc """
  Provider transport over a capability map containing budget, cancellation,
  provider timeout/retry policy, and event-sink fields from the execution run.
  Providers receive only the request, stream sink, and configured options.
  """

  require Logger
  alias Alto.{Event, Usage}
  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Call

  @doc "Dispatch a model request and return its outcome with updated run accounting."
  def request(_request, %{provider: nil} = run, _sink),
    do: {{:error, :provider_required}, run}

  def request(_request, %{model_requests: count, max_steps: limit} = run, _sink)
      when is_integer(limit) and count >= limit,
      do: {{:error, {:model_step_limit, limit}}, run}

  def request(request, run, sink) do
    {provider, opts} = run.provider
    step = run.model_requests + 1
    Alto.Events.notify(run.event_sink, Event.live(:model_started, %{step: step}))
    outcome = stream(provider, request, sink, opts, run, step)
    run = %{run | model_requests: step}

    case outcome do
      {:ok, completion} when is_map(completion) ->
        usage = Usage.normalize(completion[:usage])
        {{:ok, Map.put(completion, :usage, usage)}, %{run | usage: Usage.merge(run.usage, usage)}}

      {:ok, other} ->
        {{:error, {:invalid_completion, other}}, run}

      {:error, _} ->
        {outcome, run}
    end
  end

  @doc "Check a request against a provider's context window and reserve output."
  @spec check_context(map(), term(), module(), keyword(), map()) ::
          {:ok, map()} | {:error, term()}
  def check_context(request, policy, provider, provider_opts, caps) do
    checked =
      Call.run(
        fn ->
          description = provider.describe(Alto.Provider.options(provider_opts))
          identity = Alto.Context.Observation.identity(provider, provider_opts, description)

          observation =
            Map.get(request, :context_observation) ||
              Alto.Context.Observation.restore(
                Map.get(request, :resume_context_observation),
                request.messages,
                request.tools,
                identity
              )

          request =
            request
            |> Map.put(:context_identity, identity)
            |> Map.put(:context_observation, observation)

          {request, policy.check.(request, description)}
        end,
        Budget.timeout(caps.budget, caps.provider_timeout),
        caps.cancel_ref
      )

    case checked do
      {request, {:ok, budget}} ->
        request =
          if is_map(budget) and Map.get(budget, :pressure, false),
            do: Map.put(request, :context_pressure, true),
            else: request

        reserve_output(request, budget)

      {_request, {:error, reason}} ->
        {:error, reason}

      {:error, _} = error ->
        error
    end
  end

  @doc "Apply a context budget's output reservation exactly once."
  def reserve_output(request, budget) when is_map(budget) and budget.reserve_output > 0 do
    requested = Map.get(request.options, "max_tokens", budget.reserve_output)

    if is_integer(requested) and requested > 0 do
      {:ok,
       %{
         request
         | options: Map.put(request.options, "max_tokens", min(requested, budget.reserve_output))
       }}
    else
      {:error, :invalid_max_tokens}
    end
  end

  def reserve_output(request, _budget), do: {:ok, request}

  @doc "Stream a model request with bounded transient-error retries before any output is delivered."
  @spec stream(module(), map(), function(), keyword(), map(), pos_integer()) ::
          term()
  def stream(provider, request, sink, provider_opts, caps, step)
      when is_atom(provider) and is_function(sink, 1) and is_integer(step) and step > 0 do
    budget = caps.budget

    invoke = fn attempt_sink ->
      with :ok <- Budget.take_model(budget),
           do: Alto.Provider.stream(provider, request, attempt_sink, provider_opts)
    end

    attempt_stream(invoke, sink, caps, step, 1)
  end

  defp attempt_stream(invoke, sink, caps, step, attempt) do
    case Call.cancellation(caps.cancel_ref) do
      {:cancelled, reason} ->
        {:error, {:cancelled, reason}}

      :continue ->
        # Shared with the provider process: output is delivered immediately,
        # and any delivery prevents a retry even if the attempt later fails.
        delivered = :atomics.new(1, [])

        if attempt > 1 do
          Alto.Events.notify(
            caps.event_sink,
            Event.live(:model_started, %{step: step, attempt: attempt})
          )
        end

        diagnostic(caps, :provider_attempt_started, %{step: step, attempt: attempt})
        started = System.monotonic_time(:millisecond)

        attempt_sink = fn event ->
          :atomics.put(delivered, 1, 1)
          sink.(event)
        end

        outcome =
          Call.run(
            fn -> invoke.(attempt_sink) end,
            Budget.timeout(caps.budget, caps.provider_timeout),
            caps.cancel_ref
          )

        diagnostic(caps, :provider_attempt_finished, %{
          step: step,
          attempt: attempt,
          duration_ms: System.monotonic_time(:millisecond) - started,
          output_delivered: :atomics.get(delivered, 1) != 0,
          outcome: outcome_kind(outcome)
        })

        decision =
          case outcome do
            {:error, {kind, _}} when kind in [:participant_failed, :cancelled] ->
              :stop

            {:error, reason} when attempt <= caps.provider_retries ->
              if :atomics.get(delivered, 1) == 0,
                do: retry_decision(caps, reason, attempt),
                else: :stop

            _ ->
              :stop
          end

        case decision do
          {:retry, delay, kind} ->
            diagnostic(caps, :provider_retry, %{
              step: step,
              attempt: attempt,
              delay_ms: delay,
              kind: kind
            })

            Alto.Events.notify(
              caps.event_sink,
              Event.live(:model_retry, %{
                step: step,
                attempt: attempt,
                max_attempts: caps.provider_retries + 1,
                delay_ms: delay,
                kind: kind
              })
            )

            with :ok <- sleep_backoff(delay, caps.cancel_ref, caps.budget),
                 do: attempt_stream(invoke, sink, caps, step, attempt + 1)

          {:error, _} = error ->
            error

          :stop ->
            outcome
        end
    end
  end

  # Persist small lifecycle facts separately from replayable loop events. Never
  # retain request bodies, headers, provider error bodies, or streamed content.
  defp diagnostic(caps, event, data) do
    if Map.get(caps, :session) do
      Alto.Runner.Execution.Session.append(caps, "provider diagnostic not persisted", fn ->
        Alto.Session.diagnostic_record(caps.session_id, event, data)
      end)
    end
  end

  defp outcome_kind({:ok, _}), do: :ok
  defp outcome_kind({:error, {:http_error, status, _}}), do: %{kind: :http_error, status: status}

  defp outcome_kind({:error, {:http_error, status, _, _}}),
    do: %{kind: :http_error, status: status}

  defp outcome_kind({:error, {:transport_error, %{reason: reason}}}) when is_atom(reason),
    do: %{kind: :transport_error, reason: reason}

  defp outcome_kind({:error, {kind, reason}}) when is_atom(kind) and is_atom(reason),
    do: %{kind: kind, reason: reason}

  defp outcome_kind({:error, {kind, _}}) when is_atom(kind), do: kind
  defp outcome_kind({:error, kind}) when is_atom(kind), do: kind
  defp outcome_kind(_), do: :error

  defp retry_decision(caps, reason, attempt) do
    policy = caps.retry_policy || (&Alto.Retry.Transient.decide/2)

    case Call.run(
           fn ->
             try do
               policy.(reason, attempt)
             catch
               _, _ ->
                 Logger.warning("retry policy failed; stopping retries")
                 :stop
             end
           end,
           Budget.timeout(caps.budget, caps.provider_timeout),
           caps.cancel_ref
         ) do
      {:error, {:cancelled, _}} = error -> error
      {:retry, delay, _} = retry when is_integer(delay) and delay >= 0 -> retry
      _ -> :stop
    end
  end

  defp sleep_backoff(delay, cancel_ref, budget) do
    receive do
      {:alto_cancel, ^cancel_ref, reason} when not is_nil(cancel_ref) ->
        {:error, {:cancelled, reason}}
    after
      Budget.timeout(budget, delay) -> :ok
    end
  end
end
