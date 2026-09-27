defmodule Alto.Providers.StreamEnvelope do
  @moduledoc false
  alias Alto.Providers.HTTPOptions
  alias Alto.Providers.SSE
  alias Alto.Retry.Transient

  @state_key :alto_stream_envelope

  def post(config, body, headers, decoder, sink) do
    initial = %{sse: SSE.new(config.max_event_bytes), completion: decoder.new()}

    with {:ok, state} <-
           request(
             config,
             headers,
             [method: :post, body: JSON.encode!(body)],
             initial,
             &consume(&1, &2, decoder, sink)
           ),
         {:ok, completion} <- finish(state, decoder, sink),
         do: decoder.result(completion)
  end

  def request(config, headers, options, initial, consume) do
    initial = %{value: initial, bytes: 0, error: nil, error_body: []}

    into = fn {:data, data}, {request, response} ->
      current = Req.Response.get_private(response, @state_key, initial)
      size = current.bytes + byte_size(data)

      next =
        cond do
          size > config.max_response_bytes ->
            %{
              current
              | error: {:error, {:provider_response_too_large, config.max_response_bytes}}
            }

          response.status in 200..299 ->
            case consume.(current.value, data) do
              {:ok, value} -> %{current | value: value, bytes: size}
              {:error, _} = error -> %{current | error: error}
            end

          current.bytes < 64_000 ->
            prefix = binary_part(data, 0, min(byte_size(data), 64_000 - current.bytes))
            %{current | bytes: size, error_body: [prefix | current.error_body]}

          true ->
            %{current | bytes: size}
        end

      response = Req.Response.put_private(response, @state_key, next)
      if next.error, do: {:halt, {request, response}}, else: {:cont, {request, response}}
    end

    case Req.request(HTTPOptions.request_options(config, headers, [into: into] ++ options)) do
      {:ok, response} ->
        state = Req.Response.get_private(response, @state_key, initial)

        cond do
          state.error ->
            state.error

          response.status in 200..299 ->
            {:ok, state.value}

          true ->
            body = state.error_body |> Enum.reverse() |> IO.iodata_to_binary()
            detail = decode_error_body(body)
            metadata = Transient.rate_limit_metadata(response.headers, detail)

            if metadata && (response.status == 429 or response.status >= 500),
              do: {:error, {:http_error, response.status, detail, metadata}},
              else: {:error, {:http_error, response.status, detail}}
        end

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp decode_error_body(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => error}} -> error
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp consume(state, data, decoder, sink) do
    with {:ok, sse, payloads} <- SSE.feed(state.sse, data) do
      completion = consume_payloads(payloads, state.completion, decoder, sink)

      if completion.error,
        do: {:error, completion.error},
        else: {:ok, %{state | sse: sse, completion: completion}}
    end
  end

  defp consume_payloads(payloads, completion, decoder, sink) do
    Enum.reduce_while(payloads, completion, fn payload, state ->
      next = decoder.consume(state, payload, sink)
      if next.error, do: {:halt, next}, else: {:cont, next}
    end)
  end

  defp finish(state, decoder, sink) do
    case SSE.finish(state.sse) do
      {:ok, payloads} ->
        {:ok, consume_payloads(payloads, state.completion, decoder, sink)}

      {:raw, raw} ->
        case JSON.decode(raw) do
          {:ok, response} -> decoder.from_response(response, sink)
          {:error, error} -> {:error, {:invalid_provider_response, error}}
        end
    end
  end
end
