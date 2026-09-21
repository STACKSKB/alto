defmodule Alto.Runner.Execution.Model do
  @moduledoc """
  Provider transport over a capability map containing budget, cancellation,
  provider timeout/retry policy, and event-sink fields from the execution run.
  Providers receive only the request, stream sink, and configured options.
  """

  alias Alto.Event
  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Call
  alias Alto.Context.Policy

  @doc "Check a request against a provider's context window and reserve output."
  @spec check_context(map(), term(), module(), keyword(), map()) ::
          {:ok, map()} | {:error, term()}
  def check_context(request, policy, provider, provider_opts, caps) do
    checked =
      Call.run(
        fn ->
          description = provider.describe(provider_opts)
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

          {request, Policy.check(policy, request, description)}
        end,
        Budget.timeout(caps.budget, caps.provider_timeout),
        caps.cancel_ref
      )

    case checked do
      {:ok, {request, {:ok, budget}}} ->
        request =
          if is_map(budget) and Map.get(budget, :pressure, false),
            do: Map.put(request, :context_pressure, true),
            else: request

        reserve_output(request, budget)

      {:ok, {_request, {:error, reason}}} ->
        {:error, reason}

      {:cancelled, reason} ->
        {:error, {:cancelled, reason}}

      {:error, reason} ->
        {:error, {:context_policy_failed, reason}}
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
          {:ok, {:ok, map() | term()} | {:error, term()} | term()}
          | {:error, term()}
          | {:cancelled, term()}
  def stream(provider, request, sink, provider_opts, caps, step)
      when is_atom(provider) and is_function(sink, 1) and is_integer(step) and step > 0 do
    budget = caps.budget

    invoke = fn attempt_sink ->
      with :ok <- Budget.take_model(budget),
           do: provider.stream(request, attempt_sink, provider_opts)
    end

    attempt_stream(invoke, sink, caps, step, 1)
  end

  defp attempt_stream(invoke, sink, caps, step, attempt) do
    case Call.cancellation(caps.cancel_ref) do
      {:cancelled, reason} ->
        {:cancelled, reason}

      :continue ->
        # Shared with the provider process: output is delivered immediately,
        # and any delivery prevents a retry even if the attempt later fails.
        delivered = :atomics.new(1, [])

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

        decision =
          case outcome do
            {:ok, {:error, reason}} when attempt <= caps.provider_retries ->
              if :atomics.get(delivered, 1) == 0,
                do: retry_decision(caps, reason, attempt),
                else: :stop

            _ ->
              :stop
          end

        case decision do
          {:retry, delay, kind} ->
            Alto.Events.notify(
              caps.event_sink,
              Event.live(:model_retry, %{
                step: step,
                attempt: attempt,
                max_attempts: caps.provider_retries + 1,
                kind: kind
              })
            )

            with :ok <- sleep_backoff(delay, caps.cancel_ref, caps.budget),
                 do: attempt_stream(invoke, sink, caps, step, attempt + 1)

          {:cancelled, reason} ->
            {:cancelled, reason}

          :stop ->
            outcome
        end
    end
  end

  defp retry_decision(caps, reason, attempt) do
    policy = caps.retry_policy

    case Call.run(
           fn -> Alto.Retry.decide(policy, reason, attempt) end,
           Budget.timeout(caps.budget, caps.provider_timeout),
           caps.cancel_ref
         ) do
      {:ok, decision} -> decision
      {:cancelled, _} = cancelled -> cancelled
      _ -> :stop
    end
  end

  defp sleep_backoff(delay, cancel_ref, budget) do
    sleep_until(System.monotonic_time(:millisecond) + Budget.timeout(budget, delay), cancel_ref)
  end

  defp sleep_until(deadline, cancel_ref) do
    if System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      Process.sleep(50)

      case Call.cancellation(cancel_ref) do
        {:cancelled, reason} -> {:cancelled, reason}
        :continue -> sleep_until(deadline, cancel_ref)
      end
    end
  end
end
