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
  def claim(channel), do: GenServer.call(channel, :claim)
  def release(channel), do: GenServer.call(channel, :release)
  def peek(channel, modes, timeout \\ 5_000), do: GenServer.call(channel, {:peek, modes}, timeout)
  def ack(channel, id, timeout \\ 5_000), do: GenServer.call(channel, {:ack, id}, timeout)
  def list(channel), do: GenServer.call(channel, :list)

  @doc "Atomically consume the oldest entry while no runner owns the channel."
  def take(channel), do: GenServer.call(channel, :take)

  @impl true
  def init(opts) do
    max_messages = Keyword.get(opts, :max_messages, 32)
    max_bytes = Keyword.get(opts, :max_bytes, 64_000)

    if is_integer(max_messages) and max_messages in 1..1024 and
         is_integer(max_bytes) and max_bytes in 1..1_000_000 do
      {:ok,
       %{
         entries: [],
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
    cond do
      not is_binary(text) or not String.valid?(text) or text == "" ->
        {:reply, {:error, :invalid_input_text}, state}

      mode not in [:steer, :follow_up] ->
        {:reply, {:error, :invalid_input_mode}, state}

      length(state.entries) >= state.max_messages or
          state.bytes + byte_size(text) > state.max_bytes ->
        {:reply, {:error, :input_capacity}, state}

      true ->
        entry = %{id: state.seq + 1, text: text, mode: mode}

        {:reply, {:ok, entry.id},
         %{
           state
           | seq: entry.id,
             bytes: state.bytes + byte_size(text),
             entries: state.entries ++ [entry]
         }}
    end
  end

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
           | bytes: state.bytes - byte_size(entry.text),
             entries: Enum.reject(state.entries, &(&1.id == id))
         }}
    end
  end

  def handle_call({:ack, _}, _, state), do: {:reply, {:error, :not_input_owner}, state}

  def handle_call(:take, _from, %{owner: nil, entries: [entry | rest]} = state),
    do:
      {:reply, {:ok, entry}, %{state | entries: rest, bytes: state.bytes - byte_size(entry.text)}}

  def handle_call(:take, _from, %{owner: nil} = state), do: {:reply, :empty, state}
  def handle_call(:take, _from, state), do: {:reply, {:error, :input_in_use}, state}

  def handle_call(:list, _from, state), do: {:reply, state.entries, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:noreply, %{state | owner: nil, monitor: nil}}

  def handle_info(_, state), do: {:noreply, state}
end
