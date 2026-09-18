defmodule Alto.Retry do
  @moduledoc "Retry decision contract. Execution owns delivery fences, deadlines and attempt budgets."
  require Logger

  @callback decide(term(), pos_integer(), keyword()) ::
              :stop | {:retry, non_neg_integer(), term()}

  def default, do: {Alto.Retry.Transient, []}
  def validate(nil), do: :ok

  def validate({module, opts}) when is_atom(module) and is_list(opts) do
    if Keyword.keyword?(opts) and Code.ensure_loaded?(module) and
         function_exported?(module, :decide, 3),
       do: :ok,
       else: {:error, :invalid_retry_policy}
  end

  def validate(_), do: {:error, :invalid_retry_policy}

  def decide(nil, reason, attempt), do: decide(default(), reason, attempt)

  def decide({module, opts}, reason, attempt) do
    case module.decide(reason, attempt, opts) do
      {:retry, delay, kind} when is_integer(delay) and delay >= 0 -> {:retry, delay, kind}
      _ -> :stop
    end
  rescue
    exception ->
      log_policy_failure(module, exception)
      :stop
  catch
    kind, value ->
      log_policy_failure(module, {kind, value})
      :stop
  end

  defp log_policy_failure(module, exception) do
    # Keep diagnostics useful without serializing the provider reason or an
    # exception message, either of which may contain credentials or prompts.
    Logger.warning("retry policy failed; stopping retries",
      retry_policy: inspect(module, limit: 1, printable_limit: 64),
      failure: failure_kind(exception)
    )
  end

  defp failure_kind({kind, _value}) when kind in [:throw, :exit], do: kind
  defp failure_kind(exception) when is_exception(exception), do: exception.__struct__
  defp failure_kind(_), do: :unknown
end
