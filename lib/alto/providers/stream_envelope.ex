defmodule Alto.Providers.StreamEnvelope do
  @moduledoc false
  alias Alto.Providers.HTTPOptions
  alias Alto.Providers.SSE

  @state_key :alto_stream_envelope

  def post(config, body, headers, decoder, sink) do
    initial = %{
      sse: SSE.new(config.max_event_bytes),
      completion: decoder.new(),
      response_bytes: 0,
      error: nil,
      error_body: [],
      error_bytes: 0
    }

    into = fn {:data, data}, {request, response} ->
      current = Req.Response.get_private(response, @state_key, initial)
      next = consume(current, response.status, data, config, decoder, sink)
      response = Req.Response.put_private(response, @state_key, next)
      if next.error, do: {:halt, {request, response}}, else: {:cont, {request, response}}
    end

    case Req.post(
           HTTPOptions.request_options(config, headers, body: JSON.encode!(body), into: into)
         ) do
      {:ok, response} ->
        state = Req.Response.get_private(response, @state_key, initial)
        result(state, response.status, decoder, sink)

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  def decode_error_body(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => error}} -> error
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp consume(%{error: error} = state, _, _, _, _, _) when not is_nil(error), do: state

  defp consume(state, status, data, config, decoder, sink) do
    state = %{state | response_bytes: state.response_bytes + byte_size(data)}

    cond do
      state.response_bytes > config.max_response_bytes ->
        %{state | error: {:model_response_too_large, config.max_response_bytes}}

      status in 200..299 ->
        case SSE.feed(state.sse, data) do
          {:ok, sse, payloads} ->
            completion = consume_payloads(payloads, state.completion, decoder, sink)
            %{state | sse: sse, completion: completion, error: completion.error}

          {:error, reason} ->
            %{state | error: reason}
        end

      true ->
        remaining = max(min(config.max_response_bytes, 64_000) - state.error_bytes, 0)
        prefix = binary_part(data, 0, min(byte_size(data), remaining))

        %{
          state
          | error_body: [prefix | state.error_body],
            error_bytes: state.error_bytes + byte_size(prefix)
        }
    end
  end

  defp consume_payloads(payloads, completion, decoder, sink) do
    Enum.reduce_while(payloads, completion, fn payload, state ->
      next = decoder.consume(state, payload, sink)
      if next.error, do: {:halt, next}, else: {:cont, next}
    end)
  end

  defp result(%{error: error}, _, _, _) when not is_nil(error), do: {:error, error}

  defp result(state, status, decoder, sink) when status in 200..299 do
    with {:ok, completion} <- finish(state, decoder, sink), do: decoder.result(completion)
  end

  defp result(state, status, _, _) do
    body = state.error_body |> Enum.reverse() |> IO.iodata_to_binary()

    {:error, {:http_error, status, decode_error_body(body)}}
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
