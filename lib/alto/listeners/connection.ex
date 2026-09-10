defmodule Alto.Listeners.Connection do
  @moduledoc """
  Transport-independent client-connection logic shared by front-end listeners.

  A transport process owns its socket, feeds command lines (one NDJSON
  envelope, no trailing newline) to `run_command/3`, and delivers registry
  notifications through `emit/5`. The transport supplies a `send_line`
  continuation — a one-argument function that writes one encoded envelope
  onto the wire, wrapping it in whatever framing the transport speaks
  (NDJSON line for the Unix socket, one text frame for WebSocket).
  """

  alias Alto.Event
  alias Alto.FrontEnd.Registry
  alias Alto.Protocol

  @default_max_line_bytes 1_048_576
  @claim_envelope_reserve 2_048
  @pull_batch 100
  @wakeup_ms 25

  def default_max_line_bytes, do: @default_max_line_bytes
  def claim_envelope_reserve, do: @claim_envelope_reserve
  def pull_batch, do: @pull_batch
  def wakeup_ms, do: @wakeup_ms

  @doc "First exchange: the hello envelope, the first pull, and the wakeup timer."
  def init_client(registry, max_line_bytes, send_line) do
    case Protocol.hello(server_message_id(), Registry.run_ids(registry), max_line_bytes) do
      {:ok, hello} -> send_line.(hello)
      {:error, :overflow} -> :ok
    end
  end

  @doc "Decode and dispatch one command line; replies go through send_line."
  # The sender must not emit empty lines; the receiver ignores them
  # (the protocol contract framing rules) rather than answering with an error.
  # `max_line_bytes` is the connection's own envelope bound: `queue_claim`
  # budgets its encoded reply against it, so claims never outgrow the wire
  # they must fit on.
  def run_command(line, registry, send_line, max_line_bytes \\ @default_max_line_bytes)
  def run_command("", _registry, _send_line, _max_line_bytes), do: :ok

  def run_command(line, registry, send_line, max_line_bytes) do
    case Protocol.decode_command(line) do
      {:ok, {:attach, id, run_id, from_seq, domains}} ->
        reply(
          send_line,
          max_line_bytes,
          id,
          Registry.attach(registry, self(), run_id, from_seq, domains),
          %{}
        )

        Registry.pull(registry, self(), @pull_batch)

      {:ok, {:start_run, id, config, task, resume}} ->
        opts = if resume, do: [resume: resume], else: []

        case Registry.start_run(registry, config, task, opts) do
          {:ok, run_id} ->
            payload =
              case Registry.run_session(registry, run_id) do
                nil -> %{"run_id" => run_id}
                session_id -> %{"run_id" => run_id, "session_id" => session_id}
              end

            send_ok(send_line, max_line_bytes, id, payload)

          {:error, reason} ->
            error_reply(send_line, max_line_bytes, id, error_code(reason), reason)
        end

      {:ok, {:runs, id}} ->
        case Registry.runs(registry) do
          {:ok, runs} ->
            send_ok(send_line, max_line_bytes, id, %{"runs" => Protocol.encode_term(runs)})

          {:error, reason} ->
            error_reply(send_line, max_line_bytes, id, error_code(reason), reason)
        end

      {:ok, {:sessions, id}} ->
        case Registry.sessions(registry) do
          {:ok, summaries} ->
            payload = %{"sessions" => Enum.map(summaries, &Protocol.encode_term/1)}

            case Protocol.ok(id, payload, max_line_bytes) do
              {:ok, line} ->
                send_line.(line)

              {:error, :overflow} ->
                error_reply(send_line, max_line_bytes, id, "internal", :sessions_overflow)
            end

          {:error, reason} ->
            error_reply(send_line, max_line_bytes, id, error_code(reason), reason)
        end

      {:ok, {:session_transcript, id, session_id}} ->
        case Registry.session_transcript(registry, session_id) do
          {:ok, transcript} ->
            send_ok(send_line, max_line_bytes, id, Protocol.encode_term(transcript))

          {:error, reason} ->
            error_reply(send_line, max_line_bytes, id, error_code(reason), reason)
        end

      {:ok, {:session_events, id, session_id, limit, cursor, run_id}} ->
        with {:ok, page} <-
               Registry.session_events(registry, session_id, min(limit, 100), cursor, run_id),
             {:ok, events} <- session_events_payload(page.events) do
          payload = %{
            "session_id" => session_id,
            "events" => events,
            "next_cursor" => page.next_cursor,
            "last_cursor" => page.last_cursor,
            "high_watermark" => page.high_watermark,
            "complete" => page.complete,
            "gap" => page.gap
          }

          send_ok(send_line, max_line_bytes, id, payload)
        else
          {:error, reason} ->
            error_reply(send_line, max_line_bytes, id, error_code(reason), reason)
        end

      {:ok, {:cancel, id, run_id, reason}} ->
        reply(
          send_line,
          max_line_bytes,
          id,
          Registry.cancel(registry, run_id, reason || :user),
          %{}
        )

      {:ok, {:approval_response, id, request_id, decision}} ->
        reply(
          send_line,
          max_line_bytes,
          id,
          Registry.approval_response(registry, request_id, decision),
          %{}
        )

      {:ok, {:queue_claim, id, count, by}} ->
        queue_claim(line, registry, send_line, max_line_bytes, id, count, by)

      {:ok, {:queue_ack, id, claim_id}} ->
        reply(send_line, max_line_bytes, id, Registry.queue_ack(registry, claim_id), %{})

      {:ok, {:queue_release, id, claim_id}} ->
        reply(send_line, max_line_bytes, id, Registry.queue_release(registry, claim_id), %{})

      {:ok, {:ops_list, id, limit, cursor, filter}} ->
        ops_list(registry, send_line, max_line_bytes, id, limit, cursor, filter)

      {:ok, {:auth, id, _object}} ->
        error_reply(
          send_line,
          max_line_bytes,
          id,
          "unsupported",
          "auth is not used by the v1 default configuration"
        )

      {:ok, {:input, id, _object}} ->
        error_reply(
          send_line,
          max_line_bytes,
          id,
          "unsupported",
          "input is reserved and not implemented in v1"
        )

      {:ok, {:reload, id, _config}} ->
        error_reply(
          send_line,
          max_line_bytes,
          id,
          "unsupported",
          "reload is not implemented in v1"
        )

      {:error, {:unknown_type, id}} ->
        error_reply(send_line, max_line_bytes, id, "unknown_type", "unrecognized message type")

      {:error, :invalid} ->
        error_reply(send_line, max_line_bytes, nil, "invalid", "malformed envelope")

      {:error, :unsupported} ->
        error_reply(
          send_line,
          max_line_bytes,
          nil,
          "unsupported",
          "overrides are not accepted in v1"
        )
    end
  end

  defp session_events_payload(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case session_event_data(record) do
        {:ok, data} ->
          event =
            record |> Map.delete("wire_data") |> Map.put("data", data) |> Protocol.encode_term()

          {:cont, {:ok, [event | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:session_event_payload, reason}}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp session_event_data(%{"wire_data" => data}), do: {:ok, data}

  defp session_event_data(record) do
    with {:ok, data} <- Alto.Session.decode_term(record["data"]),
         do: {:ok, Protocol.encode_term(data)}
  end

  # Bounded claims: the byte budget derives from this connection's
  # envelope bound, and the reply is encoded against the same bound. If the
  # estimate ever misses and the reply overflows, the just-leased records
  # are released back rather than stranded as invisible leases — storage
  # success followed by a dropped wire response is never acceptable.
  defp queue_claim(_line, registry, send_line, max_line_bytes, id, count, by) do
    budget = max(max_line_bytes - @claim_envelope_reserve, 0)

    case Registry.queue_claim(registry, count, by, budget) do
      {:ok, records} ->
        payload = %{"records" => Enum.map(records, &Protocol.encode_term/1)}

        case Protocol.ok(id, payload, max_line_bytes) do
          {:ok, line} ->
            send_line.(line)

          {:error, :overflow} ->
            Enum.each(records, fn record ->
              _ = Registry.queue_release(registry, record.claim_id)
            end)

            error_reply(
              send_line,
              max_line_bytes,
              id,
              "internal",
              {:claim_response_overflow, length(records)}
            )
        end

      {:error, reason} ->
        error_reply(send_line, max_line_bytes, id, error_code(reason), reason)
    end
  end

  # Bounded operator inspection (, read-only): the page is encoded
  # against this connection's envelope bound like any other reply. An
  # overflow answers `internal` with nothing leased, written, or approved
  # — inspection never mutates, so there is nothing to roll back.
  defp ops_list(registry, send_line, max_line_bytes, id, limit, cursor, filter) do
    opts =
      [limit: min(limit, 100), cursor: cursor]
      |> then(fn opts ->
        # Static mapping only: never mint atoms from wire input. Unknown
        # filter strings pass through unchanged and fail closed in
        # `Alto.Ops.validate_filter/1` (`{:invalid_filter, _}` → `invalid`).
        if filter do
          status =
            case filter do
              "all" -> :all
              "accepted" -> :accepted
              "claimed" -> :claimed
              "parked" -> :parked
              "unknown" -> :unknown
              "completed" -> :completed
              other -> other
            end

          Keyword.put(opts, :filter, status)
        else
          opts
        end
      end)

    case Registry.ops_list(registry, opts) do
      {:ok, %{items: items, next_cursor: next_cursor}} ->
        payload = %{
          "items" => Enum.map(items, &Protocol.encode_term/1),
          "next_cursor" => next_cursor
        }

        case Protocol.ok(id, payload, max_line_bytes) do
          {:ok, line} ->
            send_line.(line)

          {:error, :overflow} ->
            error_reply(send_line, max_line_bytes, id, "internal", :ops_overflow)
        end

      {:error, reason} ->
        error_reply(send_line, max_line_bytes, id, error_code(reason), reason)
    end
  end

  @doc "Encode one registry notification for the wire, with the overflow fallback."
  def emit(notification, registry, max_line_bytes, send_line) do
    encoded =
      case notification do
        {:event, run_id, seq, %Event{} = event} ->
          Protocol.event(server_message_id(), run_id, seq, event, max_line_bytes)

        {:attached, run_id, gap, head_seq, replay} ->
          Protocol.attached(server_message_id(), run_id, gap, head_seq, replay, max_line_bytes)

        {:approval_request, run_id, request} ->
          Protocol.approval_request(server_message_id(), run_id, request, max_line_bytes)

        {:approval_resolved, run_id, request, decision} ->
          Protocol.approval_resolved(
            server_message_id(),
            run_id,
            request,
            decision,
            max_line_bytes
          )

        {:result, run_id, outcome, output, model_requests} ->
          Protocol.result(
            server_message_id(),
            run_id,
            outcome,
            output,
            model_requests,
            max_line_bytes
          )

        {:overflow, run_id, domain, last_seq} ->
          Protocol.overflow(server_message_id(), run_id, domain, last_seq, max_line_bytes)
      end

    case encoded do
      {:ok, line} ->
        send_line.(line)

      {:error, :overflow} ->
        # The envelope itself is over the announced bound; the overflow
        # notice (small by construction) tells the client what was lost.
        {:ok, line} =
          Protocol.overflow(
            server_message_id(),
            run_id_of(notification),
            overflow_domain(notification),
            nil,
            max_line_bytes
          )

        send_line.(line)
    end

    Registry.pull(registry, self(), @pull_batch)
  end

  defp reply(send_line, max_line_bytes, id, :ok, payload),
    do: send_ok(send_line, max_line_bytes, id, payload)

  defp reply(send_line, max_line_bytes, id, {:error, reason}, _payload) do
    error_reply(send_line, max_line_bytes, id, error_code(reason), reason)
  end

  defp error_code(:unknown_run), do: "unknown_run"
  defp error_code({:unknown_config, _config}), do: "not_found"
  defp error_code(:not_found), do: "not_found"
  defp error_code(:invalid), do: "invalid"
  defp error_code(:no_queue), do: "unsupported"
  defp error_code(:no_ops), do: "unsupported"
  defp error_code(:lease_expired), do: "not_found"
  defp error_code({:queue_unavailable, _reason}), do: "internal"
  defp error_code({:ops_unavailable, _reason}), do: "internal"
  defp error_code({:record_too_large, _detail}), do: "internal"
  defp error_code({:claim_response_overflow, _detail}), do: "internal"
  defp error_code(:ops_overflow), do: "internal"
  defp error_code({:invalid_limit, _}), do: "invalid"
  defp error_code({:invalid_cursor, _}), do: "invalid"
  defp error_code({:invalid_event_cursor, _}), do: "invalid"
  defp error_code({:invalid_event_limit, _}), do: "invalid"
  defp error_code({:invalid_event_run_id, _}), do: "invalid"
  defp error_code({:invalid_filter, _}), do: "invalid"
  # resume failures: unknown or unrestorable sessions are `not_found`
  # with the reason in the detail; unreadable stores are `internal`, and a
  # malformed resume option is `invalid`. A crashed (snapshot-less) session
  # reports `:no_resumable_transcript` — the actual recoverable state —
  # instead of running anything.
  defp error_code(:no_resumable_transcript), do: "not_found"
  defp error_code({:session_not_found, _id}), do: "not_found"
  defp error_code({:invalid_session_id, _id}), do: "invalid"
  defp error_code({:invalid_resume_option, _opt}), do: "invalid"
  defp error_code({:session_read_failed, _reason}), do: "internal"
  defp error_code({:session_corrupt, _id, _line}), do: "internal"
  defp error_code(_other), do: "internal"

  defp send_ok(send_line, max_line_bytes, id, payload) do
    case Protocol.ok(id, payload, max_line_bytes) do
      {:ok, line} ->
        send_line.(line)

      {:error, :overflow} ->
        error_reply(send_line, max_line_bytes, id, "internal", :reply_overflow)
    end
  end

  defp error_reply(send_line, max_line_bytes, id, code, detail) do
    {:ok, line} = Protocol.error(id, code, detail, max_line_bytes)
    send_line.(line)
  end

  defp run_id_of({:event, run_id, _seq, _event}), do: run_id
  defp run_id_of({:attached, run_id, _gap, _head, _replay}), do: run_id
  defp run_id_of({:approval_request, run_id, _request}), do: run_id
  defp run_id_of({:approval_resolved, run_id, _request, _decision}), do: run_id
  defp run_id_of({:result, run_id, _outcome, _output, _requests}), do: run_id
  defp run_id_of({:overflow, run_id, _domain, _last_seq}), do: run_id

  defp overflow_domain({:event, _run_id, seq, _event}) when is_integer(seq), do: :durable
  defp overflow_domain({:attached, _run_id, _gap, _head, _replay}), do: :durable
  defp overflow_domain(_other), do: :live

  defp server_message_id, do: "s-" <> Integer.to_string(System.unique_integer([:positive]))
end
