defmodule Alto.Protocol do
  @moduledoc """
  Envelope codec for the Alto front-end protocol v1 (the protocol contract).

  The envelope is the protocol; transports are framing. This module is pure
  and host-independent: it encodes server-to-client messages and decodes
  client-to-server commands, and defines the lossy term encoding for event
  data and approval details. Exactness lives in the durable log, never on the
  wire.

  Every encoder takes `max_line_bytes` and never emits a truncated envelope:
  an oversized message returns `{:error, :overflow}` so the transport can send
  an `overflow` notice instead. One consequence of the spec's `attached`
  shape, which nests the replayed event envelopes: a replay larger than
  `max_line_bytes` also overflows, so listeners must bound their retained
  buffers accordingly.
  """

  alias Alto.Approval.Request, as: ApprovalRequest
  alias Alto.Event

  @version 1
  @max_inspect_bytes 1_000
  @domains ~w(durable live)

  @type command ::
          {:attach, String.t(), String.t() | nil, pos_integer(), [atom()]}
          | {:start_run, String.t(), String.t(), String.t(), String.t() | nil}
          | {:sessions, String.t()}
          | {:runs, String.t()}
          | {:session_transcript, String.t(), String.t()}
          | {:session_events, String.t(), String.t(), pos_integer(), non_neg_integer(),
             String.t() | nil}
          | {:cancel, String.t(), String.t(), String.t() | nil}
          | {:approval_response, String.t(), String.t(), :approve | {:deny, String.t()}}
          | {:queue_claim, String.t(), pos_integer(), String.t() | nil}
          | {:queue_ack, String.t(), String.t()}
          | {:queue_release, String.t(), String.t()}
          | {:ops_list, String.t(), pos_integer(), non_neg_integer(), String.t() | nil}
          | {:reload, String.t(), String.t()}
          | {:auth, String.t(), map()}
          | {:input, String.t(), map()}

  @doc "The protocol version this codec speaks."
  @spec version() :: pos_integer()
  def version, do: @version

  ## Term encoding

  @doc """
  The wire encoding for Elixir terms, per the protocol contract. Lossy but stable:
  tuples become `{"$tuple": [...]}` and unencodable terms become a bounded
  `inspect/1` string. Applied after the host's own bounds, never instead of
  them.
  """
  @spec encode_term(term()) :: term()
  def encode_term(term)
      when is_binary(term) or is_integer(term) or is_float(term) or is_boolean(term) or
             is_nil(term),
      do: term

  def encode_term(atom) when is_atom(atom), do: Atom.to_string(atom)

  # Structs are maps but not Enumerable; encode them as their field maps.
  def encode_term(%_{} = struct), do: encode_term(Map.from_struct(struct))

  def encode_term(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {encode_key(key), encode_term(value)} end)

  def encode_term(list) when is_list(list), do: encode_list(list)

  def encode_term(tuple) when is_tuple(tuple),
    do: %{"$tuple" => encode_term(Tuple.to_list(tuple))}

  def encode_term(other), do: %{"$inspect" => bounded_inspect(other)}

  # Walks improper lists too: a term that would crash the encoder must not
  # take the connection process down with it.
  defp encode_list([head | tail]), do: [encode_term(head) | encode_list(tail)]
  defp encode_list([]), do: []
  defp encode_list(other), do: [encode_term(other)]

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key) when is_binary(key), do: key
  defp encode_key(key) when is_integer(key), do: Integer.to_string(key)
  defp encode_key(key), do: bounded_inspect(key)

  defp bounded_inspect(term) do
    inspect(term, pretty: false, limit: 50, printable_limit: @max_inspect_bytes)
    |> trim_valid(@max_inspect_bytes)
  end

  defp trim_valid(binary, max) when byte_size(binary) <= max, do: binary

  defp trim_valid(binary, max) do
    kept = binary_part(binary, 0, max)

    if String.valid?(kept) do
      kept <> "…"
    else
      trim_valid(binary_part(kept, 0, byte_size(kept) - 1), max)
    end
  end

  ## Server → client encoding

  @spec hello(String.t(), [String.t()], pos_integer()) :: {:ok, iodata()} | {:error, :overflow}
  def hello(id, run_ids, max_line_bytes) do
    encode(
      %{"type" => "hello", "id" => id, "runs" => run_ids, "max_line_bytes" => max_line_bytes},
      max_line_bytes
    )
  end

  @spec event(String.t(), String.t(), non_neg_integer() | nil, Event.t(), pos_integer()) ::
          {:ok, iodata()} | {:error, :overflow}
  def event(id, run_id, seq, %Event{} = event, max_line_bytes) do
    encode(
      %{
        "type" => "event",
        "id" => id,
        "run_id" => run_id,
        "seq" => seq,
        "domain" => Atom.to_string(event.domain),
        "at_ms" => event.at_ms,
        "event" => %{"type" => Atom.to_string(event.type), "data" => encode_term(event.data)}
      },
      max_line_bytes
    )
  end

  @spec attached(
          String.t(),
          String.t(),
          boolean(),
          non_neg_integer() | nil,
          [
            {non_neg_integer(), Event.t()}
          ],
          pos_integer()
        ) :: {:ok, iodata()} | {:error, :overflow}
  def attached(id, run_id, gap, head_seq, replay, max_line_bytes) do
    encode(
      %{
        "type" => "attached",
        "id" => id,
        "run_id" => run_id,
        "gap" => gap,
        "head_seq" => head_seq,
        "events" => Enum.map(replay, fn {seq, event} -> event_object(seq, event) end)
      },
      max_line_bytes
    )
  end

  @spec approval_request(String.t(), String.t(), ApprovalRequest.t(), pos_integer()) ::
          {:ok, iodata()} | {:error, :overflow}
  def approval_request(id, run_id, %ApprovalRequest{} = request, max_line_bytes) do
    encode(
      %{
        "type" => "approval_request",
        "id" => id,
        "run_id" => run_id,
        "request" => request_object(request)
      },
      max_line_bytes
    )
  end

  @spec approval_resolved(String.t(), String.t(), ApprovalRequest.t(), term(), pos_integer()) ::
          {:ok, iodata()} | {:error, :overflow}
  def approval_resolved(id, run_id, %ApprovalRequest{} = request, decision, max_line_bytes) do
    encode(
      %{
        "type" => "approval_resolved",
        "id" => id,
        "run_id" => run_id,
        "request" => request_object(request),
        "decision" => encode_term(decision)
      },
      max_line_bytes
    )
  end

  @spec result(
          String.t(),
          String.t(),
          :ok | {:error, term()} | {:cancelled, term()},
          term(),
          non_neg_integer(),
          pos_integer()
        ) :: {:ok, iodata()} | {:error, :overflow}
  def result(id, run_id, outcome, output, model_requests, max_line_bytes) do
    {outcome_name, reason_field} =
      case outcome do
        :ok -> {"ok", %{}}
        {:error, reason} -> {"error", %{"reason" => encode_term(reason)}}
        {:cancelled, reason} -> {"cancelled", %{"reason" => encode_term(reason)}}
      end

    payload =
      %{
        "type" => "result",
        "id" => id,
        "run_id" => run_id,
        "outcome" => outcome_name,
        "model_requests" => model_requests
      }
      |> Map.merge(reason_field)
      |> maybe_put("output", output)

    encode(payload, max_line_bytes)
  end

  @spec overflow(String.t(), String.t(), :durable | :live, non_neg_integer() | nil, pos_integer()) ::
          {:ok, iodata()} | {:error, :overflow}
  def overflow(id, run_id, domain, last_seq, max_line_bytes) when domain in [:durable, :live] do
    encode(
      %{
        "type" => "overflow",
        "id" => id,
        "run_id" => run_id,
        "domain" => Atom.to_string(domain),
        "last_seq" => last_seq
      },
      max_line_bytes
    )
  end

  @spec error(String.t() | nil, String.t(), term(), pos_integer()) :: {:ok, iodata()}
  def error(id, code, detail, max_line_bytes) do
    encode(
      %{"type" => "error", "id" => id, "code" => code, "detail" => encode_term(detail)},
      max_line_bytes
    )
  end

  @spec ok(String.t() | nil, map(), pos_integer()) :: {:ok, iodata()} | {:error, :overflow}
  def ok(id, payload, max_line_bytes) do
    encode(Map.merge(%{"type" => "ok", "id" => id}, encode_term(payload)), max_line_bytes)
  end

  defp event_object(seq, %Event{} = event) do
    %{
      "seq" => seq,
      "domain" => Atom.to_string(event.domain),
      "at_ms" => event.at_ms,
      "event" => %{"type" => Atom.to_string(event.type), "data" => encode_term(event.data)}
    }
  end

  defp request_object(%ApprovalRequest{} = request) do
    %{
      "id" => request.id,
      "run_id" => request.run_id,
      "call_id" => request.call_id,
      "operation_id" => request.operation_id,
      "tool" => request.tool,
      "arguments" => encode_term(request.arguments),
      "execution_mode" => Atom.to_string(request.execution_mode),
      "details" => encode_term(request.details)
    }
  end

  defp encode(payload, max_line_bytes) do
    line = [JSON.encode!(Map.merge(%{"v" => @version}, payload)), "\n"]

    if IO.iodata_length(line) <= max_line_bytes do
      {:ok, line}
    else
      {:error, :overflow}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, encode_term(value))

  ## Client → server decoding

  @doc """
  Decode one NDJSON command line. Malformed JSON, a missing envelope header,
  or a wrong major version decode to `{:error, :invalid}`; a well-formed
  envelope with an unknown type decodes to `{:error, {:unknown_type, id}}` so
  the receiver can echo the correlation token; a field the v1 server must
  reject (start_run overrides) decodes to `{:error, :unsupported}`.
  """
  @spec decode_command(binary()) ::
          {:ok, command()}
          | {:error, :invalid}
          | {:error, {:unknown_type, String.t()}}
          | {:error, :unsupported}
  def decode_command(line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, %{"v" => @version, "type" => type, "id" => id} = object}
      when is_binary(type) and is_binary(id) and id != "" ->
        decode_object(type, id, object)

      {:ok, _other} ->
        {:error, :invalid}

      {:error, _error} ->
        {:error, :invalid}
    end
  end

  defp decode_object("attach", id, object) do
    with {:ok, run_id} <- optional_binary(object, "run_id"),
         {:ok, from_seq} <- optional_positive_integer(object, "from_seq"),
         {:ok, domains} <- optional_domains(object, "domains") do
      {:ok, {:attach, id, run_id, from_seq, domains}}
    end
  end

  defp decode_object("start_run", id, object) do
    if Map.has_key?(object, "overrides") do
      {:error, :unsupported}
    else
      with {:ok, config} <- required_binary(object, "config"),
           {:ok, task} <- required_binary(object, "task"),
           {:ok, resume} <- optional_binary(object, "resume") do
        {:ok, {:start_run, id, config, task, resume}}
      end
    end
  end

  defp decode_object("runs", id, _object), do: {:ok, {:runs, id}}

  defp decode_object("sessions", id, _object) do
    {:ok, {:sessions, id}}
  end

  defp decode_object("session_transcript", id, object) do
    with {:ok, session_id} <- required_binary(object, "session_id"),
         :ok <-
           if(Map.has_key?(object, "limit") or Map.has_key?(object, "cursor"),
             do: {:error, :unsupported},
             else: :ok
           ) do
      {:ok, {:session_transcript, id, session_id}}
    end
  end

  defp decode_object("session_events", id, object) do
    with {:ok, session_id} <- required_binary(object, "session_id"),
         {:ok, limit} <- optional_ops_limit(object, "limit"),
         {:ok, cursor} <- optional_non_negative_integer(object, "cursor"),
         {:ok, run_id} <- optional_binary(object, "run_id") do
      {:ok, {:session_events, id, session_id, limit, cursor, run_id}}
    end
  end

  defp decode_object("cancel", id, object) do
    with {:ok, run_id} <- required_binary(object, "run_id"),
         {:ok, reason} <- optional_binary(object, "reason") do
      {:ok, {:cancel, id, run_id, reason}}
    end
  end

  defp decode_object("approval_response", id, object) do
    with {:ok, request_id} <- required_binary(object, "request_id"),
         {:ok, decision} <- decision(object, "decision") do
      {:ok, {:approval_response, id, request_id, decision}}
    end
  end

  defp decode_object("queue_claim", id, object) do
    with {:ok, count} <- optional_positive_integer(object, "count"),
         {:ok, by} <- optional_binary(object, "by") do
      {:ok, {:queue_claim, id, count, by}}
    end
  end

  defp decode_object("queue_ack", id, object) do
    with {:ok, claim_id} <- required_binary(object, "claim_id") do
      {:ok, {:queue_ack, id, claim_id}}
    end
  end

  defp decode_object("queue_release", id, object) do
    with {:ok, claim_id} <- required_binary(object, "claim_id") do
      {:ok, {:queue_release, id, claim_id}}
    end
  end

  defp decode_object("ops_list", id, object) do
    with {:ok, limit} <- optional_ops_limit(object, "limit"),
         {:ok, cursor} <- optional_non_negative_integer(object, "cursor"),
         {:ok, filter} <- optional_filter(object, "filter") do
      {:ok, {:ops_list, id, limit, cursor, filter}}
    end
  end

  defp decode_object("reload", id, object) do
    with {:ok, config} <- required_binary(object, "config") do
      {:ok, {:reload, id, config}}
    end
  end

  defp decode_object("auth", id, object) when is_map(object), do: {:ok, {:auth, id, object}}

  defp decode_object("input", id, object) when is_map(object), do: {:ok, {:input, id, object}}

  defp decode_object(_type, id, _object), do: {:error, {:unknown_type, id}}

  defp required_binary(object, key) do
    case Map.get(object, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :invalid}
    end
  end

  defp optional_binary(object, key) do
    case Map.get(object, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, :invalid}
    end
  end

  defp optional_positive_integer(object, key) do
    case Map.get(object, key) do
      nil -> {:ok, 1}
      value when is_integer(value) and value >= 1 -> {:ok, value}
      _other -> {:error, :invalid}
    end
  end

  defp optional_non_negative_integer(object, key) do
    case Map.get(object, key) do
      nil -> {:ok, 0}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, :invalid}
    end
  end

  defp optional_ops_limit(object, key) do
    case Map.get(object, key) do
      nil -> {:ok, 20}
      value when is_integer(value) and value >= 1 -> {:ok, value}
      _other -> {:error, :invalid}
    end
  end

  defp optional_filter(object, key) do
    case Map.get(object, key) do
      nil ->
        {:ok, nil}

      value
      when value in ["all", "accepted", "claimed", "parked", "unknown", "completed"] ->
        {:ok, value}

      _other ->
        {:error, :invalid}
    end
  end

  defp optional_domains(object, key) do
    case Map.get(object, key) do
      nil ->
        {:ok, [:durable, :live]}

      domains when is_list(domains) ->
        if domains != [] and Enum.all?(domains, &(&1 in @domains)) do
          {:ok, Enum.map(domains, &String.to_existing_atom/1)}
        else
          {:error, :invalid}
        end

      _other ->
        {:error, :invalid}
    end
  end

  defp decision(object, key) do
    case Map.get(object, key) do
      "approve" ->
        {:ok, :approve}

      %{"deny" => reason} when is_binary(reason) ->
        {:ok, {:deny, reason}}

      _other ->
        {:error, :invalid}
    end
  end
end
