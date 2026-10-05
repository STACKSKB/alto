defmodule Alto.Contrib.Providers.StreamEnvelope do
  @moduledoc false
  alias Alto.Contrib.Providers.HTTPOptions
  alias Alto.Contrib.Providers.SSE
  alias Alto.Contrib.Retry.Transient
  alias Alto.Provider.Failure

  @state_key :alto_stream_envelope

  def post(config, body, headers, decoder, sink) do
    initial = %{
      sse: SSE.new(config.max_event_bytes),
      completion: decoder.new(),
      events: 0,
      diagnostics: %{}
    }

    on_error = fn reason, state, diagnostics ->
      evidence = accounting(state.completion, decoder)

      diagnostics =
        Map.merge(diagnostics, %{
          max_event_bytes: config.max_event_bytes,
          max_stream_bytes: config.max_response_bytes
        })

      {:error,
       Failure.wrap(
         Failure.reason(reason),
         Map.update(evidence, :diagnostics, diagnostics, &Map.merge(&1, diagnostics))
       )}
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
        {:ok, completion, final_events} ->
          diagnostics =
            Map.merge(
              Map.get(accounting(completion, decoder), :diagnostics, %{}),
              Map.merge(state.diagnostics, %{
                events: state.events + final_events,
                max_event_bytes: config.max_event_bytes,
                max_stream_bytes: config.max_response_bytes
              })
            )

          case decoder.result(completion) do
            {:ok, result} ->
              {:ok, Map.put(result, :diagnostics, diagnostics)}

            {:error, reason} ->
              {:error,
               Failure.wrap(
                 Failure.reason(reason),
                 Map.put(accounting(completion, decoder), :diagnostics, diagnostics)
               )}
          end

        {:error, reason} ->
          on_error.(reason, state, state.diagnostics)
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
    initial = %{
      value: initial,
      bytes: 0,
      accepted_bytes: 0,
      first_byte_ms: nil,
      last_byte_ms: nil,
      http_status: nil,
      started: System.monotonic_time(:millisecond),
      error: nil,
      error_body: []
    }

    ref = make_ref()
    Process.put(ref, initial)

    into = fn {:data, data}, {request, response} ->
      current = Req.Response.get_private(response, @state_key, initial)
      size = current.bytes + byte_size(data)
      at = System.monotonic_time(:millisecond) - current.started

      current = %{
        current
        | first_byte_ms: current.first_byte_ms || at,
          last_byte_ms: at,
          http_status: response.status
      }

      next =
        cond do
          size > config.max_response_bytes ->
            %{
              current
              | bytes: size,
                error: {:error, {:provider_response_too_large, config.max_response_bytes}}
            }

          response.status in 200..299 ->
            value =
              if is_map(current.value) and Map.has_key?(current.value, :sse),
                do:
                  Map.put(
                    current.value,
                    :diagnostics,
                    diagnostics(%{current | bytes: size}, response.status)
                  ),
                else: current.value

            case consume.(value, data) do
              {:ok, value} ->
                %{current | value: value, bytes: size, accepted_bytes: size}

              {:error, reason, value} ->
                %{
                  current
                  | value: value,
                    bytes: size,
                    accepted_bytes: size,
                    error: {:error, reason}
                }

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
              value =
                if is_map(state.value) and Map.has_key?(state.value, :sse),
                  do: Map.put(state.value, :diagnostics, diagnostics(state, response.status)),
                  else: state.value

              {:ok, value}

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
      accepted_bytes: state.accepted_bytes,
      first_byte_ms: state.first_byte_ms,
      last_byte_ms: state.last_byte_ms,
      events: if(is_map(state.value), do: Map.get(state.value, :events, 0), else: 0),
      http_status: status || state.http_status
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
      progress_sink = fn
        %Alto.Event{type: :provider_accounting, data: evidence} = event ->
          sink.(%{
            event
            | data:
                Map.update(
                  evidence,
                  :diagnostics,
                  state.diagnostics,
                  &Map.merge(&1, state.diagnostics)
                )
          })

        event ->
          sink.(event)
      end

      completion = consume_payloads(payloads, state.completion, decoder, progress_sink)

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
        {:ok, consume_payloads(payloads, state.completion, decoder, sink), length(payloads)}

      {:raw, raw} ->
        case JSON.decode(raw) do
          {:ok, response} ->
            case decoder.from_response(response, sink) do
              {:ok, completion} ->
                snapshot =
                  accounting(completion, decoder)
                  |> Map.update!(:usage, &Alto.Contrib.Usage.known/1)

                sink.(Alto.Event.live(:provider_accounting, snapshot))
                {:ok, completion, 0}

              error ->
                error
            end

          {:error, error} ->
            {:error, {:invalid_provider_response, error}}
        end
    end
  end
end
