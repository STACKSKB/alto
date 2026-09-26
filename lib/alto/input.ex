defmodule Alto.Input do
  @moduledoc """
  Bounded input channel shared by interactive execution hosts.

  `:steer` messages are delivered before the next model request, once dispatched
  tools settle. `:follow_up` messages are delivered when the loop would finish.
  Entries remain queued until execution acknowledges their insertion or an idle
  host takes the next turn. A host owns the channel lifetime and can reuse it
  across runs; portable mailbox snapshots retain queued entries and receipts across checkpoints.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def enqueue(channel, message), do: request(channel, {:enqueue, message})
  @doc false
  def duplicate(channel, message), do: request(channel, {:duplicate, message})
  def receipt(channel, message_id), do: request(channel, {:receipt, message_id})

  def pending?(channel, modes \\ [:steer, :follow_up]),
    do: request(channel, {:pending, modes})

  def claim(channel), do: request(channel, :claim)
  def release(channel), do: request(channel, :release)
  def list(channel), do: request(channel, :list)

  @doc "Atomically consume the oldest entry while no runner owns the channel."
  def take(channel, sender_kind \\ :any), do: request(channel, {:take, sender_kind})

  @doc "Open a channel using a host-selected transport (memory by default)."
  def open(opts \\ []), do: Alto.Messaging.Transport.open(opts)

  @doc false
  def request(
        %Alto.Messaging.Transport.Channel{module: module, handle: handle},
        operation,
        timeout
      ),
      do: module.request(handle, operation, timeout)

  def request(channel, operation, timeout), do: GenServer.call(channel, operation, timeout)
  def request(channel, operation), do: request(channel, operation, 5_000)

  def close(%Alto.Messaging.Transport.Channel{module: module, handle: handle}),
    do: module.close(handle)

  def close(channel) when is_pid(channel) do
    if Process.alive?(channel), do: GenServer.stop(channel), else: :ok
  end

  @doc false
  def checkpoint(channel), do: request(channel, :checkpoint)
  @doc "A portable queue, receipt and deduplication snapshot; reader authority is excluded."
  def snapshot(channel), do: request(channel, :snapshot)
  def restore(channel, snapshot), do: request(channel, {:restore, snapshot})

  def read(channel, token, modes, timeout \\ 5_000),
    do: request(channel, {:read, token, modes}, timeout)

  def settle(channel, token, id), do: request(channel, {:settle, token, id})

  def acknowledge(channel, token, id, status, timeout \\ 5_000),
    do: request(channel, {:acknowledge, token, id, status}, timeout)

  @impl true
  def init(opts) do
    max_messages = Keyword.get(opts, :max_messages, 32)
    max_bytes = Keyword.get(opts, :max_bytes, 64_000)

    if is_integer(max_messages) and max_messages in 1..1024 and
         is_integer(max_bytes) and max_bytes in 1..1_000_000 do
      {:ok,
       %{
         identity: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
         reader: nil,
         sealed: false,
         entries: [],
         receipts: %{},
         keys: %{},
         bytes: 0,
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
  def handle_call(:claim, {pid, _}, %{owner: nil} = state) do
    token = random_token()

    {:reply, {:ok, token},
     %{state | owner: pid, reader: token, monitor: if(is_pid(pid), do: Process.monitor(pid))}}
  end

  def handle_call(:claim, _from, state), do: {:reply, {:error, :input_in_use}, state}

  def handle_call(:release, {pid, _}, %{owner: pid} = state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    {:reply, :ok, %{state | owner: nil, monitor: nil, reader: nil}}
  end

  def handle_call(:release, _, state), do: {:reply, {:error, :not_input_owner}, state}

  def handle_call(:checkpoint, _, state),
    do:
      {:reply, {:ok, Map.drop(state, [:owner, :monitor, :reader, :sealed])},
       %{state | sealed: true}}

  def handle_call(:snapshot, _, state),
    do: {:reply, {:ok, Map.drop(state, [:owner, :monitor, :reader, :sealed])}, state}

  def handle_call({:restore, saved}, _, state) do
    cond do
      not valid_snapshot?(saved) ->
        {:reply, {:error, :invalid_input_snapshot}, state}

      saved.identity == state.identity and
          map_size(state.receipts) >= map_size(saved.receipts) ->
        {:reply, :ok, %{state | sealed: false}}

      state.receipts == %{} and saved.bytes <= state.max_bytes and
          length(saved.entries) <= state.max_messages ->
        merged = Map.merge(state, saved)

        {:reply, :ok,
         %{
           merged
           | sealed: false,
             max_messages: min(state.max_messages, saved.max_messages),
             max_bytes: min(state.max_bytes, saved.max_bytes)
         }}

      true ->
        {:reply, {:error, :input_snapshot_conflict}, state}
    end
  end

  def handle_call({:settle, token, id}, _, %{reader: token, owner: owner} = state)
      when not is_nil(token) and not is_nil(owner) do
    case state.receipts[id] do
      %{status: :unknown} = receipt ->
        {:reply, :ok, put_in(state.receipts[id], %{receipt | status: :delivered})}

      nil ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :invalid_receipt_state}, state}
    end
  end

  def handle_call({:settle, _, _}, _, state), do: {:reply, {:error, :not_input_owner}, state}

  def handle_call({:duplicate, message}, _from, state),
    do: {:reply, duplicate_receipt(message, state) || {:error, :recipient_closed}, state}

  def handle_call({:receipt, id}, _from, state),
    do: {:reply, Map.fetch(state.receipts, id), state}

  def handle_call({:pending, modes}, _from, state),
    do: {:reply, Enum.any?(state.entries, &(&1.mode in modes)), state}

  def handle_call({:read, token, modes}, _, %{reader: token, owner: owner} = state)
      when not is_nil(token) and not is_nil(owner) and is_list(modes),
      do: {:reply, Enum.find(state.entries, &(&1.mode in modes)), state}

  def handle_call({:read, _, _}, _, state), do: {:reply, {:error, :not_input_owner}, state}

  def handle_call({:acknowledge, token, id, status}, _, %{reader: token, owner: owner} = state)
      when not is_nil(token) and not is_nil(owner) and status in [:consumed, :delivered, :unknown] do
    case Enum.find(state.entries, &(&1.message_id == id)) do
      nil ->
        {:reply, {:error, :unknown_input}, state}

      entry ->
        {:reply, :ok, consume(state, entry, status)}
    end
  end

  def handle_call({:acknowledge, token, _, _}, _, %{reader: token, owner: owner} = state)
      when not is_nil(token) and not is_nil(owner),
      do: {:reply, {:error, :invalid_input_operation}, state}

  def handle_call({:acknowledge, _, _, _}, _, state),
    do: {:reply, {:error, :not_input_owner}, state}

  def handle_call({:take, kind}, _from, %{owner: nil} = state) do
    case Enum.find(state.entries, &(kind == :any or &1.sender.kind == kind)) do
      nil ->
        {:reply, :empty, state}

      entry ->
        {:reply, {:ok, entry}, consume(state, entry, :taken)}
    end
  end

  def handle_call({:take, _}, _from, state), do: {:reply, {:error, :input_in_use}, state}

  def handle_call(:list, _from, state), do: {:reply, state.entries, state}

  def handle_call({:enqueue, message}, _from, state) do
    bytes = entry_bytes(message)
    duplicate = duplicate_receipt(message, state)

    cond do
      duplicate != nil ->
        {:reply, duplicate, state}

      state.sealed ->
        {:reply, {:error, :input_checkpointed}, state}

      length(state.entries) >= state.max_messages or state.bytes + bytes > state.max_bytes ->
        {:reply, {:error, :input_capacity}, state}

      map_size(state.receipts) >= 4096 ->
        {:reply, {:error, :receipt_capacity}, state}

      true ->
        message_id = "msg-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
        entry = Map.put(message, :message_id, message_id)
        receipt = %{message_id: message_id, status: :queued}

        keys =
          case message[:idempotency_key] do
            nil -> state.keys
            key -> Map.put(state.keys, {message.sender, key}, {fingerprint(message), message_id})
          end

        {:reply, {:ok, receipt},
         %{
           state
           | bytes: state.bytes + bytes,
             entries: state.entries ++ [entry],
             receipts: Map.put(state.receipts, message_id, receipt),
             keys: keys
         }}
    end
  end

  @doc false
  def valid_snapshot?(saved) when is_map(saved) do
    with true <- map_size(saved) == 7,
         true <- is_binary(saved.identity) and byte_size(saved.identity) in 1..128,
         true <- is_integer(saved.max_messages) and saved.max_messages in 1..1024,
         true <- is_integer(saved.max_bytes) and saved.max_bytes in 1..1_000_000,
         true <- is_list(saved.entries) and length(saved.entries) <= saved.max_messages,
         true <- is_map(saved.receipts) and map_size(saved.receipts) <= 4096,
         true <- is_map(saved.keys) and map_size(saved.keys) <= 4096,
         true <-
           Enum.all?(saved.receipts, fn {id, receipt} ->
             is_binary(id) and is_map(receipt) and receipt.message_id == id and
               receipt.status in [:queued, :consumed, :taken, :delivered, :unknown]
           end),
         true <-
           Enum.all?(saved.keys, fn
             {{sender, key}, {hash, id}} ->
               is_map(sender) and is_binary(key) and
                 is_binary(hash) and byte_size(hash) == 32 and Map.has_key?(saved.receipts, id)

             _ ->
               false
           end),
         true <-
           Enum.all?(saved.entries, fn e ->
             is_map(e) and is_binary(e.message_id) and
               Alto.Messaging.valid_message?(e) and valid_sender?(e.sender) and
               match?(%{status: :queued}, saved.receipts[e.message_id])
           end),
         true <- length(Enum.uniq_by(saved.entries, & &1.message_id)) == length(saved.entries),
         true <- saved.bytes == Enum.sum(Enum.map(saved.entries, &entry_bytes/1)),
         true <- saved.bytes <= saved.max_bytes do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def valid_snapshot?(_), do: false
  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp valid_sender?(%{kind: :user}), do: true
  defp valid_sender?(%{kind: :agent, id: id}), do: is_binary(id)
  defp valid_sender?(_), do: false

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
    # Routed metadata consumes capacity in addition to text.
    byte_size(text) +
      if(Map.has_key?(message, :recipient),
        do: :erlang.external_size(Map.drop(message, [:text, :message_id])),
        else: 0
      )
  end

  defp consume(state, entry, status) do
    %{
      state
      | bytes: state.bytes - entry_bytes(entry),
        entries: Enum.reject(state.entries, &(&1.message_id == entry.message_id)),
        receipts: Map.update!(state.receipts, entry.message_id, &%{&1 | status: status})
    }
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:noreply, %{state | owner: nil, monitor: nil, reader: nil}}

  def handle_info(_, state), do: {:noreply, state}
end
