defmodule Alto.Listeners.Connection do
  @moduledoc """
  Shared command dispatch and notification encoding for front-end transports.

  Each operation returns complete bounded wire envelopes. Transports own
  framing and delivery; command handlers return results before encoding.
  """

  alias Alto.FrontEnd.Registry
  alias Alto.Protocol

  @default_max_line_bytes 1_048_576
  @claim_envelope_reserve 2_048
  @pull_batch 100
  @wakeup_ms 25
  @direct_commands ~w(session_transcript list_agents approval_response queue_ack queue_release)a
  @filters Map.new(~w(all accepted claimed parked unknown completed)a, &{Atom.to_string(&1), &1})

  def default_max_line_bytes, do: @default_max_line_bytes
  def claim_envelope_reserve, do: @claim_envelope_reserve
  def pull_batch, do: @pull_batch
  def wakeup_ms, do: @wakeup_ms

  def hello_lines(registry, max_line_bytes) do
    case Protocol.envelope(
           "hello",
           server_message_id(),
           %{runs: Registry.request(registry, :run_ids), max_line_bytes: max_line_bytes},
           max_line_bytes
         ) do
      {:ok, line} -> [line]
      {:error, :overflow} -> []
    end
  end

  def command_lines(line, registry, max_line_bytes \\ @default_max_line_bytes)
  def command_lines("", _registry, _max_line_bytes), do: []

  def command_lines(line, registry, max_line_bytes) do
    case Protocol.decode_command(line) do
      {:ok, {:queue_claim, id, [count, by]}} ->
        queue_claim(registry, id, count, by, max_line_bytes)

      {:ok, {kind, id, args}} ->
        reply(id, execute(kind, args, registry), max_line_bytes)

      {:error, {:unknown_type, id}} ->
        error_lines(id, "unknown_type", "unrecognized message type", max_line_bytes)

      {:error, :invalid} ->
        error_lines(nil, "invalid", "malformed envelope", max_line_bytes)

      {:error, :unsupported} ->
        error_lines(nil, "unsupported", "overrides are not accepted", max_line_bytes)
    end
  end

  defp execute(:attach, [run_id, from_seq, domains], registry) do
    result = Registry.request(registry, {:attach, self(), run_id, from_seq, domains})
    Registry.pull(registry, self(), @pull_batch)
    result
  end

  defp execute(:start_run, [config, task, resume], registry) do
    opts = if resume, do: [resume: resume], else: []

    with {:ok, run_id} <- Registry.request(registry, {:start_run, config, task, opts}) do
      payload = %{"run_id" => run_id}
      session_id = Registry.request(registry, {:run_session, run_id})
      {:ok, if(session_id, do: Map.put(payload, "session_id", session_id), else: payload)}
    end
  end

  defp execute(kind, [], registry) when kind in [:runs, :sessions] do
    with {:ok, items} <- Registry.request(registry, kind), do: {:ok, %{kind => items}}
  end

  defp execute(:session_events, [session_id, limit, cursor, run_id], registry) do
    with {:ok, page} <-
           Registry.request(
             registry,
             {:session_events, session_id, min(limit, 100), cursor, run_id}
           ),
         {:ok, events} <- session_events_payload(page.events) do
      {:ok, page |> Map.put(:session_id, session_id) |> Map.put(:events, events)}
    end
  end

  defp execute(
         :send_message,
         [run_id, %Alto.Content{} = content, to, delivery, key, reply_to],
         registry
       ) do
    text = content |> Alto.Content.text_value() |> Alto.Text.truncate(63_000, "…")

    Registry.request(
      registry,
      {:send_message, run_id,
       [
         text: text,
         content: content.blocks,
         to: to,
         delivery: delivery,
         idempotency_key: key,
         in_reply_to: reply_to
       ]}
    )
  end

  defp execute(:send_message, [run_id, text, to, delivery, key, reply_to], registry),
    do:
      Registry.request(
        registry,
        {:send_message, run_id,
         [text: text, to: to, delivery: delivery, idempotency_key: key, in_reply_to: reply_to]}
      )

  defp execute(:cancel, [run_id, reason], registry),
    do: Registry.request(registry, {:cancel, run_id, reason || :user})

  defp execute(:ops_list, [limit, cursor, filter], registry) do
    # Protocol validates against a fixed set; no atoms are minted from wire input.
    opts = [limit: min(limit, 100), cursor: cursor]
    opts = if filter, do: Keyword.put(opts, :filter, Map.fetch!(@filters, filter)), else: opts
    Registry.request(registry, {:ops_list, opts})
  end

  defp execute(kind, args, registry) when kind in @direct_commands,
    do: Registry.request(registry, List.to_tuple([kind | args]))

  defp execute(:command, [name, payload], registry),
    do: Registry.command(registry, name, payload)

  defp execute(kind, _args, _registry) when kind in [:auth, :input, :reload],
    do: {:error, :unsupported}

  defp session_events_payload(records) do
    Alto.Result.traverse(records, fn record ->
      case session_event_data(record) do
        {:ok, data} ->
          {:ok,
           record |> Map.delete("wire_data") |> Map.put("data", data) |> Protocol.encode_term()}

        {:error, reason} ->
          {:error, {:session_event_payload, reason}}
      end
    end)
  end

  defp session_event_data(%{"wire_data" => data}), do: {:ok, data}

  defp session_event_data(record) do
    with {:ok, data} <- Alto.Session.decode_term(record["data"]),
         do: {:ok, Protocol.encode_term(data)}
  end

  # Leases must not survive an encoded reply that cannot fit the wire.
  defp queue_claim(registry, id, count, by, max_line_bytes) do
    budget = max(max_line_bytes - @claim_envelope_reserve, 0)

    case Registry.request(registry, {:queue_claim, count, by, budget}) do
      {:ok, records} ->
        case Protocol.envelope("ok", id, %{records: records}, max_line_bytes) do
          {:ok, line} ->
            [line]

          {:error, :overflow} ->
            Enum.each(records, &Registry.request(registry, {:queue_release, &1.claim_id}))

            error_lines(
              id,
              "internal",
              {:claim_response_overflow, length(records)},
              max_line_bytes
            )
        end

      error ->
        reply(id, error, max_line_bytes)
    end
  end

  @doc "Encode a registry notification and request the next bounded delivery batch."
  def notification_lines(notification, registry, max_line_bytes) do
    encoded = Protocol.notification(server_message_id(), notification, max_line_bytes)

    encoded =
      case encoded do
        {:ok, _} ->
          encoded

        {:error, :overflow} ->
          Protocol.notification(
            server_message_id(),
            {:overflow, elem(notification, 1), overflow_domain(notification), nil},
            max_line_bytes
          )
      end

    Registry.pull(registry, self(), @pull_batch)
    lines(encoded)
  end

  defp reply(id, :ok, max), do: reply(id, {:ok, %{}}, max)

  defp reply(id, {:ok, payload}, max) do
    case Protocol.envelope("ok", id, payload, max) do
      {:ok, line} -> [line]
      {:error, :overflow} -> error_lines(id, "internal", :reply_overflow, max)
    end
  end

  defp reply(id, {:error, reason}, max), do: error_lines(id, error_code(reason), reason, max)

  defp error_lines(id, code, detail, max),
    do: lines(Protocol.envelope("error", id, %{code: code, detail: detail}, max))

  defp lines({:ok, line}), do: [line]

  defp error_code(:recipient_closed), do: "closed"

  defp error_code(reason) when reason in [:input_capacity, :receipt_capacity, :agent_capacity],
    do: "capacity"

  defp error_code(reason) when reason in [:invalid_message, :idempotency_conflict], do: "invalid"
  defp error_code(:unknown_agent), do: "not_found"

  defp error_code(reason) when reason in [:unknown_run, :unknown_command],
    do: Atom.to_string(reason)

  defp error_code(reason) when reason in [:invalid, :invalid_command], do: "invalid"

  defp error_code(reason) when reason in [:not_found, :lease_expired, :no_resumable_transcript],
    do: "not_found"

  defp error_code(reason) when reason in [:unsupported, :no_queue, :no_ops], do: "unsupported"
  defp error_code({kind, _}) when kind in [:unknown_config, :session_not_found], do: "not_found"

  defp error_code({kind, _})
       when kind in [
              :invalid_limit,
              :invalid_cursor,
              :invalid_event_cursor,
              :invalid_event_limit,
              :invalid_event_run_id,
              :invalid_filter,
              :invalid_session_id,
              :invalid_resume_option
            ],
       do: "invalid"

  defp error_code(_), do: "internal"

  defp overflow_domain({:event, _run_id, seq, _event}) when is_integer(seq), do: :durable
  defp overflow_domain({:attached, _run_id, _gap, _head, _replay}), do: :durable
  defp overflow_domain(_other), do: :live

  defp server_message_id, do: "s-" <> Integer.to_string(System.unique_integer([:positive]))
end
