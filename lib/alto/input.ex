defmodule Alto.Input do
  @moduledoc """
  Bounded input channel shared by interactive execution hosts.

  `:steer` messages are delivered before the next model request, once dispatched
  tools settle. `:follow_up` messages are delivered when the loop would finish.
  Entries remain queued until execution acknowledges their insertion or an idle
  host takes the next turn. A host owns the channel lifetime and can reuse it
  across runs; channels are not serialized into execution checkpoints.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def put(channel, text, mode \\ :steer), do: GenServer.call(channel, {:put, text, mode})
  @doc false
  def enqueue(channel, message), do: GenServer.call(channel, {:enqueue, message})
  @doc false
  def duplicate(channel, message), do: GenServer.call(channel, {:duplicate, message})
  def receipt(channel, message_id), do: GenServer.call(channel, {:receipt, message_id})

  def pending?(channel, modes \\ [:steer, :follow_up]),
    do: GenServer.call(channel, {:pending, modes})

  def claim(channel), do: GenServer.call(channel, :claim)
  def release(channel), do: GenServer.call(channel, :release)
  def peek(channel, modes, timeout \\ 5_000), do: GenServer.call(channel, {:peek, modes}, timeout)
  def ack(channel, id, timeout \\ 5_000), do: GenServer.call(channel, {:ack, id}, timeout)
  def list(channel), do: GenServer.call(channel, :list)

  @doc "Atomically consume the oldest entry while no runner owns the channel."
  def take(channel, sender_kind \\ :any), do: GenServer.call(channel, {:take, sender_kind})

  @impl true
  def init(opts) do
    max_messages = Keyword.get(opts, :max_messages, 32)
    max_bytes = Keyword.get(opts, :max_bytes, 64_000)

    if is_integer(max_messages) and max_messages in 1..1024 and
         is_integer(max_bytes) and max_bytes in 1..1_000_000 do
      {:ok,
       %{
         entries: [],
         receipts: %{},
         keys: %{},
         bytes: 0,
         seq: 0,
         owner: nil,
         monitor: nil,
         max_messages: max_messages,
         max_bytes: max_bytes
       }}
    else
      {:stop, :invalid_input_bounds}
    end
  end

  @impl true
  def handle_call(:claim, {pid, _}, %{owner: nil} = state),
    do: {:reply, :ok, %{state | owner: pid, monitor: Process.monitor(pid)}}

  def handle_call(:claim, _from, state), do: {:reply, {:error, :input_in_use}, state}

  def handle_call(:release, {pid, _}, %{owner: pid} = state) do
    Process.demonitor(state.monitor, [:flush])
    {:reply, :ok, %{state | owner: nil, monitor: nil}}
  end

  def handle_call(:release, _, state), do: {:reply, {:error, :not_input_owner}, state}

  def handle_call({:put, text, mode}, _from, state) do
    enqueue(%{text: text, mode: mode, sender: %{kind: :user}}, state, :legacy)
  end

  def handle_call({:enqueue, message}, _from, state), do: enqueue(message, state, :receipt)

  def handle_call({:duplicate, message}, _from, state),
    do: {:reply, duplicate_receipt(message, state) || {:error, :recipient_closed}, state}

  def handle_call({:receipt, id}, _from, state),
    do: {:reply, Map.fetch(state.receipts, id), state}

  def handle_call({:pending, modes}, _from, state),
    do: {:reply, Enum.any?(state.entries, &(&1.mode in modes)), state}

  def handle_call({:peek, modes}, {pid, _}, %{owner: pid} = state) when is_list(modes),
    do: {:reply, Enum.find(state.entries, &(&1.mode in modes)), state}

  def handle_call({:peek, _}, _, state), do: {:reply, {:error, :not_input_owner}, state}

  def handle_call({:ack, id}, {pid, _}, %{owner: pid} = state) do
    case Enum.find(state.entries, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :unknown_input}, state}

      entry ->
        {:reply, :ok,
         %{
           state
           | bytes: state.bytes - entry_bytes(entry),
             receipts: consumed(state.receipts, entry),
             entries: Enum.reject(state.entries, &(&1.id == id))
         }}
    end
  end

  def handle_call({:ack, _}, _, state), do: {:reply, {:error, :not_input_owner}, state}

  def handle_call({:take, kind}, _from, %{owner: nil} = state) do
    case Enum.find(state.entries, &(kind == :any or &1.sender.kind == kind)) do
      nil ->
        {:reply, :empty, state}

      entry ->
        {:reply, {:ok, entry},
         %{
           state
           | entries: Enum.reject(state.entries, &(&1.id == entry.id)),
             bytes: state.bytes - entry_bytes(entry),
             receipts: consumed(state.receipts, entry, :taken)
         }}
    end
  end

  def handle_call({:take, _}, _from, state), do: {:reply, {:error, :input_in_use}, state}

  def handle_call(:list, _from, state), do: {:reply, state.entries, state}

  defp enqueue(message, state, reply_kind) do
    text = message.text
    bytes = entry_bytes(message)
    duplicate = duplicate_receipt(message, state)

    cond do
      not is_binary(text) or not String.valid?(text) or text == "" ->
        {:reply, {:error, :invalid_input_text}, state}

      message.mode not in [:steer, :follow_up] ->
        {:reply, {:error, :invalid_input_mode}, state}

      duplicate != nil ->
        {:reply, duplicate, state}

      length(state.entries) >= state.max_messages or state.bytes + bytes > state.max_bytes ->
        {:reply, {:error, :input_capacity}, state}

      reply_kind == :receipt and map_size(state.receipts) >= 4096 ->
        {:reply, {:error, :receipt_capacity}, state}

      true ->
        id = state.seq + 1
        message_id = "msg-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
        entry = Map.merge(message, %{id: id, message_id: message_id})
        receipt = %{message_id: message_id, status: :queued}

        receipts =
          if reply_kind == :receipt,
            do: Map.put(state.receipts, message_id, receipt),
            else: state.receipts

        keys =
          case message[:idempotency_key] do
            nil -> state.keys
            key -> Map.put(state.keys, {message.sender, key}, {fingerprint(message), message_id})
          end

        reply = if reply_kind == :legacy, do: {:ok, id}, else: {:ok, receipt}

        {:reply, reply,
         %{
           state
           | seq: id,
             bytes: state.bytes + bytes,
             entries: state.entries ++ [entry],
             receipts: receipts,
             keys: keys
         }}
    end
  end

  defp duplicate_receipt(%{idempotency_key: key} = message, state) when not is_nil(key) do
    case state.keys[{message.sender, key}] do
      nil ->
        nil

      {hash, id} ->
        if hash == fingerprint(message),
          do: {:ok, state.receipts[id]},
          else: {:error, :idempotency_conflict}
    end
  end

  defp duplicate_receipt(_, _), do: nil
  defp fingerprint(message), do: :crypto.hash(:sha256, :erlang.term_to_binary(message))

  defp entry_bytes(%{text: text} = message) do
    if is_binary(text) do
      # Preserve legacy text-byte bounds; routed metadata also consumes capacity.
      byte_size(text) +
        if(Map.has_key?(message, :recipient),
          do: :erlang.external_size(Map.drop(message, [:text, :id, :message_id])),
          else: 0
        )
    else
      0
    end
  end

  defp consumed(receipts, entry, status \\ :consumed) do
    if Map.has_key?(receipts, entry.message_id),
      do: Map.update!(receipts, entry.message_id, &%{&1 | status: status}),
      else: receipts
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:noreply, %{state | owner: nil, monitor: nil}}

  def handle_info(_, state), do: {:noreply, state}
end
