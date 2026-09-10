defmodule Alto.Runner.Execution.Model do
  @moduledoc "The provider transport boundary shared by execution hosts."

  alias Alto.Event
  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Call
  alias Alto.Context.Window

  defmodule Capabilities do
    @moduledoc "The bounded capabilities required for one provider request."
    @enforce_keys [:budget, :cancel_ref, :provider_timeout, :provider_retries, :event_sink]
    defstruct [:budget, :cancel_ref, :provider_timeout, :provider_retries, :event_sink]

    @type t :: %__MODULE__{
            budget: Budget.t(),
            cancel_ref: reference() | nil,
            provider_timeout: pos_integer(),
            provider_retries: non_neg_integer(),
            event_sink: (Event.t() -> term()) | nil
          }
  end

  @doc "Check a request against a provider's context window and reserve output."
  @spec check_context(map(), Window.t(), module(), keyword(), Capabilities.t()) ::
          {:ok, map()} | {:error, term()}
  def check_context(request, %Window{} = policy, provider, provider_opts, %Capabilities{} = caps) do
    checked =
      Call.run(
        fn -> Window.check(policy, request, provider.describe(provider_opts)) end,
        Budget.timeout(caps.budget, caps.provider_timeout),
        caps.cancel_ref
      )

    case checked do
      {:ok, {:ok, budget}} -> reserve_output(request, budget)
      {:ok, {:error, reason}} -> {:error, reason}
      {:cancelled, reason} -> {:error, {:cancelled, reason}}
      {:error, reason} -> {:error, {:context_policy_failed, reason}}
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

  @doc "Stream a model request with bounded, transport-only retries."
  @spec stream(module(), map(), function(), keyword(), Capabilities.t(), pos_integer()) ::
          {:ok, {:ok, map() | term()} | {:error, term()} | term()}
          | {:error, term()}
          | {:cancelled, term()}
  def stream(provider, request, sink, provider_opts, %Capabilities{} = caps, step)
      when is_atom(provider) and is_function(sink, 1) and is_integer(step) and step > 0 do
    stream_with_retries(provider, request, sink, provider_opts, caps, step)
  end

  @doc "Public name for the retrying transport operation."
  def stream_with_retries(provider, request, sink, provider_opts, %Capabilities{} = caps, step) do
    attempt_stream(
      provider,
      request,
      sink,
      provider_opts,
      caps,
      step,
      1,
      caps.provider_retries + 1
    )
  end

  defp attempt_stream(provider, request, sink, provider_opts, caps, step, attempt, max_attempts) do
    case Call.cancellation(caps.cancel_ref) do
      {:cancelled, reason} ->
        {:cancelled, reason}

      :continue ->
        outcome =
          Call.run(
            fn ->
              with :ok <- Budget.take_model(caps.budget),
                   do: provider.stream(request, sink, provider_opts)
            end,
            Budget.timeout(caps.budget, caps.provider_timeout),
            caps.cancel_ref
          )

        maybe_retry_stream(
          outcome,
          provider,
          request,
          sink,
          provider_opts,
          caps,
          step,
          attempt,
          max_attempts
        )
    end
  end

  defp maybe_retry_stream(
         {:ok, {:error, reason}} = outcome,
         provider,
         request,
         sink,
         provider_opts,
         caps,
         step,
         attempt,
         max_attempts
       ) do
    if attempt < max_attempts and retryable_stream_error?(reason) do
      notify(
        caps.event_sink,
        Event.live(:model_retry, %{
          step: step,
          attempt: attempt,
          max_attempts: max_attempts,
          kind: stream_error_kind(reason)
        })
      )

      case sleep_backoff(attempt, caps.cancel_ref, caps.budget) do
        :ok ->
          attempt_stream(
            provider,
            request,
            sink,
            provider_opts,
            caps,
            step,
            attempt + 1,
            max_attempts
          )

        {:cancelled, reason} ->
          {:cancelled, reason}
      end
    else
      outcome
    end
  end

  defp maybe_retry_stream(
         outcome,
         _provider,
         _request,
         _sink,
         _opts,
         _caps,
         _step,
         _attempt,
         _max
       ),
       do: outcome

  @doc false
  def retryable_stream_error?({:transport_error, _reason}), do: true
  def retryable_stream_error?({:http_error, 429, _detail}), do: true
  def retryable_stream_error?({:http_error, status, _detail}) when status >= 500, do: true
  def retryable_stream_error?(_reason), do: false

  @doc false
  def stream_error_kind({:transport_error, _reason}), do: :transport
  def stream_error_kind({:http_error, status, _detail}), do: {:http, status}

  @doc false
  def sleep_backoff(attempt, cancel_ref, budget) do
    backoff = min(500 * Integer.pow(2, attempt - 1), 5_000)
    sleep_until(System.monotonic_time(:millisecond) + Budget.timeout(budget, backoff), cancel_ref)
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

  defp notify(sink, event) do
    sink.(event)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
