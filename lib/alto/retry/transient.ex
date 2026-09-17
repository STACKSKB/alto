defmodule Alto.Retry.Transient do
  @moduledoc "Conservative transient transport classification with exponential backoff."
  @behaviour Alto.Retry
  @impl true
  def decide(reason, attempt, opts) do
    if retryable_stream_error?(reason) do
      delay =
        min(
          Keyword.get(opts, :base_delay, 500) * Integer.pow(2, attempt - 1),
          Keyword.get(opts, :max_delay, 5_000)
        )

      {:retry, delay, stream_error_kind(reason)}
    else
      :stop
    end
  end

  defp retryable_stream_error?({:transport_error, _reason}), do: true
  defp retryable_stream_error?({:http_error, 429, _detail}), do: true
  defp retryable_stream_error?({:http_error, status, _detail}) when status >= 500, do: true
  # Match the observed structured transient error, not arbitrary provider text
  # or loosely coerced codes. HTTP 200 SSE errors do not carry an HTTP status.
  defp retryable_stream_error?(
         {:provider_error,
          %{"code" => 502, "metadata" => %{"error_type" => "provider_unavailable"}}}
       ),
       do: true

  defp retryable_stream_error?(
         {:provider_error, %{"code" => 504, "metadata" => %{"error_type" => "timeout"}}}
       ),
       do: true

  defp retryable_stream_error?(_reason), do: false

  defp stream_error_kind({:transport_error, _reason}), do: :transport
  defp stream_error_kind({:http_error, status, _detail}), do: {:http, status}
  defp stream_error_kind({:provider_error, %{"code" => 502}}), do: {:provider, 502}
  defp stream_error_kind({:provider_error, %{"code" => 504}}), do: {:provider, 504}
end
