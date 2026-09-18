defmodule Alto.Retry.Transient do
  @moduledoc """
  Transient transport classification with capped exponential backoff and full jitter.
  Set `jitter: false` for fixed delays, or supply a zero-arity `random_source`
  returning a number in 0..1 for deterministic scheduling tests.
  """
  @behaviour Alto.Retry
  @impl true
  def decide(reason, attempt, opts) do
    case stream_error_kind(reason) do
      nil ->
        :stop

      kind ->
        delay =
          min(
            Keyword.get(opts, :base_delay, 500) * Integer.pow(2, attempt - 1),
            Keyword.get(opts, :max_delay, 5_000)
          )

        {:retry, jitter(delay, opts), kind}
    end
  end

  # Match the observed structured transient error, not arbitrary provider text
  # or loosely coerced codes. HTTP 200 SSE errors do not carry an HTTP status.
  defp stream_error_kind({:transport_error, _reason}), do: :transport
  defp stream_error_kind({:http_error, 429, _detail}), do: {:http, 429}
  defp stream_error_kind({:http_error, status, _detail}) when status >= 500, do: {:http, status}

  defp stream_error_kind(
         {:provider_error,
          %{"code" => 502, "metadata" => %{"error_type" => "provider_unavailable"}}}
       ),
       do: {:provider, 502}

  defp stream_error_kind(
         {:provider_error, %{"code" => 504, "metadata" => %{"error_type" => "timeout"}}}
       ),
       do: {:provider, 504}

  defp stream_error_kind(_reason), do: nil

  defp jitter(delay, opts) do
    if Keyword.get(opts, :jitter, true) do
      sample = Keyword.get(opts, :random_source, &:rand.uniform/0).()

      if is_number(sample) and sample >= 0 and sample <= 1,
        do: trunc(delay * sample),
        else: raise(ArgumentError, "retry random_source must return a number in 0..1")
    else
      delay
    end
  end
end
