defmodule Alto.Retry.Transient do
  @moduledoc """
  Transient transport classification with capped exponential backoff and full jitter.
  Set `jitter: false` for fixed delays, or supply a zero-arity `random_source`
  returning a number in 0..1 for deterministic scheduling tests.
  """
  @max_server_wait_ms 60_000

  def rate_limit_metadata(headers, detail, now_ms \\ System.system_time(:millisecond)) do
    metadata =
      [headers, body_headers(detail)]
      |> Enum.flat_map(&header_pairs/1)
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        case normalize_key(key) do
          "retry-after" ->
            put_valid_hint(
              acc,
              :retry_after_ms,
              parse_retry_after(normalize_value(value), now_ms)
            )

          "x-ratelimit-reset" ->
            put_valid_hint(acc, :rate_limit_reset_ms, parse_reset(normalize_value(value), now_ms))

          _ ->
            acc
        end
      end)

    if map_size(metadata) == 0, do: nil, else: metadata
  end

  def decide(reason, attempt, opts \\ []) do
    case stream_error_kind(reason) do
      nil ->
        :stop

      kind ->
        delay =
          min(
            Keyword.get(opts, :base_delay, 500) * Integer.pow(2, attempt - 1),
            Keyword.get(opts, :max_delay, 5_000)
          )

        server_min = server_delay(reason, opts)

        cond do
          is_integer(server_min) and server_min > @max_server_wait_ms -> :stop
          is_integer(server_min) -> {:retry, max(server_min, jitter(delay, opts)), kind}
          true -> {:retry, jitter(delay, opts), kind}
        end
    end
  end

  # Match the observed structured transient error, not arbitrary provider text
  # or loosely coerced codes. HTTP 200 SSE errors do not carry an HTTP status.
  defp stream_error_kind({:transport_error, _reason}), do: :transport
  defp stream_error_kind({:http_error, 429, _detail}), do: {:http, 429}
  defp stream_error_kind({:http_error, 429, _detail, _metadata}), do: {:http, 429}
  defp stream_error_kind({:http_error, status, _detail}) when status >= 500, do: {:http, status}

  defp stream_error_kind({:http_error, status, _detail, _metadata}) when status >= 500,
    do: {:http, status}

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

  defp server_delay({:http_error, status, detail, metadata}, opts)
       when (status == 429 or status >= 500) and is_map(metadata) do
    metadata_delay(metadata) || derived_server_delay(detail, opts)
  end

  defp server_delay({:http_error, status, detail}, opts) when status == 429 or status >= 500,
    do: derived_server_delay(detail, opts)

  defp server_delay(_, _opts), do: nil

  defp derived_server_delay(detail, opts) do
    rate_limit_metadata([], detail, Keyword.get(opts, :now_ms, System.system_time(:millisecond)))
    |> metadata_delay()
  end

  defp metadata_delay(nil), do: nil

  defp metadata_delay(metadata) do
    [metadata[:retry_after_ms], metadata[:rate_limit_reset_ms]]
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> Enum.max(fn -> nil end)
  end

  defp body_headers(%{"metadata" => %{"headers" => headers}}), do: headers
  defp body_headers(_), do: nil

  defp header_pairs(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {key, value} -> [{key, value}]
      _ -> []
    end)
  end

  defp header_pairs(headers) when is_map(headers), do: Enum.to_list(headers)
  defp header_pairs(_), do: []

  defp normalize_key(key) when is_binary(key) and byte_size(key) <= 80 do
    if String.valid?(key), do: String.downcase(key), else: ""
  end

  defp normalize_key(_), do: ""

  defp normalize_value([value | _]) when is_binary(value), do: value
  defp normalize_value(value), do: value

  defp parse_retry_after(value, now_ms) do
    case bounded_string(value) do
      nil ->
        nil

      raw ->
        case Integer.parse(String.trim(raw)) do
          {seconds, ""} when seconds >= 0 -> min(seconds * 1_000, 60_001)
          _ -> parse_http_date(raw, now_ms)
        end
    end
  end

  defp parse_http_date(raw, now_ms) do
    case Req.Utils.parse_http_date(raw) do
      {:ok, datetime} -> min(max(DateTime.to_unix(datetime, :millisecond) - now_ms, 0), 60_001)
      _ -> nil
    end
  end

  defp parse_reset(value, now_ms) do
    case bounded_string(value) do
      nil ->
        nil

      raw ->
        case Float.parse(String.trim(raw)) do
          {number, ""} when number >= 1.0e12 ->
            min(max(trunc(number) - now_ms, 0), 60_001)

          {number, ""} when number >= 0 ->
            min(max(ceil(number * 1_000 - now_ms), 0), 60_001)

          _ ->
            nil
        end
    end
  end

  defp bounded_string(value) when is_binary(value) and byte_size(value) <= 128,
    do: if(String.valid?(value), do: value, else: nil)

  defp bounded_string(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp bounded_string(_), do: nil

  defp put_valid_hint(map, _key, nil), do: map
  defp put_valid_hint(map, key, value), do: Map.put_new(map, key, value)

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
