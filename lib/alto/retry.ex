defmodule Alto.Retry do
  @moduledoc "Retry decision contract. Execution owns delivery fences, deadlines and attempt budgets."
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
    _ -> :stop
  catch
    _, _ -> :stop
  end
end
