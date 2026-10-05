defmodule Alto.Contrib.Providers.StreamEnvelope do
  @moduledoc false
  alias Alto.Contrib.Providers.HTTPOptions
  alias Alto.Contrib.Providers.SSE
  alias Alto.Contrib.Retry.Transient
  alias Alto.Provider.Failure

  @state_key :alto_stream_envelope

  def post(config, body, headers, decoder, sink) do
    initial = %{sse: SSE.new(config.max_event_bytes), completion: decoder.new(), events: 0}

    on_error = fn reason, state, diagnostics ->
      evidence = accounting(state.completion, decoder)
      {:error, Failure.wrap(Failure.reason(reason), Map.put(evidence, :diagnostics, diagnostics))}
    end

    with {:ok, state} <-
           request(
             config,
             headers,
             [method: :post, body: JSON.encode!(body)],
             initial,
             &consume(&1, &2, decoder, sink),
             on_error
           ) do
      case finish(state, decoder, sink) do
        {:ok, completion} -> decoder.result(completion)
        {:error, reason} -> on_error.(reason, state, %{events: state.events})
      end
    end
  end

  def request(
        config,
        headers,
        options,
        initial,
        consume,
        on_error \\ fn reason, _, _ -> {:error, reason} end
      ) do
    initial = %{value: initial, bytes: 0, error: nil, error_body: []}

    ref = make_ref()
    Process.put(ref, initial)

    into = fn {:data, data}, {request, response} ->
      current = Req.Response.get_private(response, @state_key, initial)
      size = current.bytes + byte_size(data)

      next =
        cond do
          size > config.max_response_bytes ->
            %{
              current
              | bytes: size,
                error: {:error, {:provider_response_too_large, config.max_response_bytes}}
            }

          response.status in 200..299 ->
            case consume.(current.value, data) do
              {:ok, value} ->
                %{current | value: value, bytes: size}

              {:error, reason, value} ->
                %{current | value: value, bytes: size, error: {:error, reason}}

              {:error, _} = error ->
                %{current | bytes: size, error: error}
            end

          current.bytes < 64_000 ->
            prefix = binary_part(data, 0, min(byte_size(data), 64_000 - current.bytes))
            %{current | bytes: size, error_body: [prefix | current.error_body]}

          true ->
            %{current | bytes: size}
        end

      Process.put(ref, next)
      response = Req.Response.put_private(response, @state_key, next)
      if next.error, do: {:halt, {request, response}}, else: {:cont, {request, response}}
    end

    try do
      case Req.request(HTTPOptions.request_options(config, headers, [into: into] ++ options)) do
        {:ok, response} ->
          state = Req.Response.get_private(response, @state_key, initial)

          cond do
            state.error ->
              {:error, reason} = state.error
              on_error.(reason, state.value, diagnostics(state, response.status))

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
          state = Process.get(ref, initial)
          on_error.({:transport_error, reason}, state.value, diagnostics(state, nil))
      end
    after
      Process.delete(ref)
    end
  end

  defp diagnostics(state, status),
    do: %{
      response_bytes: state.bytes,
      events: if(is_map(state.value), do: Map.get(state.value, :events, 0), else: 0),
      http_status: status
    }

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

      next = %{state | sse: sse, completion: completion, events: state.events + length(payloads)}
      if completion.error, do: {:error, completion.error, next}, else: {:ok, next}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp consume_payloads(payloads, completion, decoder, sink) do
    Enum.reduce_while(payloads, completion, fn payload, state ->
      next = decoder.consume(state, payload, sink)

      if accounting(next, decoder) != accounting(state, decoder) do
        snapshot = accounting(next, decoder)
        snapshot = Map.update!(snapshot, :usage, &Alto.Contrib.Usage.known/1)
        sink.(Alto.Event.live(:provider_accounting, snapshot))
      end

      if next.error, do: {:halt, next}, else: {:cont, next}
    end)
  end

  defp accounting(state, decoder) do
    if function_exported?(decoder, :accounting, 1),
      do: decoder.accounting(state),
      else: %{usage: Map.get(state, :usage), metadata: %{}}
  end

  defp finish(state, decoder, sink) do
    case SSE.finish(state.sse) do
      {:ok, payloads} ->
        {:ok, consume_payloads(payloads, state.completion, decoder, sink)}

      {:raw, raw} ->
        case JSON.decode(raw) do
          {:ok, response} ->
            case decoder.from_response(response, sink) do
              {:ok, completion} = result ->
                snapshot =
                  accounting(completion, decoder)
                  |> Map.update!(:usage, &Alto.Contrib.Usage.known/1)

                sink.(Alto.Event.live(:provider_accounting, snapshot))
                result

              error ->
                error
            end

          {:error, error} ->
            {:error, {:invalid_provider_response, error}}
        end
    end
  end
end
