defmodule Alto.Messaging do
  @moduledoc """
  Bounded, in-memory routing within one execution tree.

  Hosts send to an input channel with `send(input, text: text)`, or to an agent
  with `send(router, agent_id, text: text)`. Tools use a runtime-issued Sender;
  its identity cannot be supplied in model arguments. Acceptance means queued,
  not processed. Routers and receipts are not durable checkpoint state.
  """
  use GenServer
  import Kernel, except: [send: 2]

  defmodule Sender do
    @moduledoc "Opaque authority to send as one registered agent."
    @enforce_keys [:router, :id, :token]
    defstruct [:router, :id, :token]
    @opaque t :: %__MODULE__{router: pid(), id: String.t(), token: reference()}
  end

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, Keyword.put_new(opts, :owner, self()))

  def send(input, opts) when is_list(opts) do
    with {:ok, message} <- envelope(opts, %{kind: :user}),
         do: safe(fn -> Alto.Input.enqueue(input, message) end)
  end

  @doc false
  def duplicate(input, opts) do
    with {:ok, message} <- envelope(opts, %{kind: :user}),
         do: safe(fn -> Alto.Input.duplicate(input, message) end)
  end

  def send(sender, recipient, opts) do
    with {:ok, message} <- envelope(opts, nil),
         do: call(sender, {:send, recipient, message})
  end

  def list(sender), do: call(sender, :list)

  @doc false
  def register(router, opts \\ []) do
    with {:ok, [sender]} <- register_many(router, [opts]), do: {:ok, sender}
  end

  @doc false
  def register_many(router, options),
    do: safe(fn -> GenServer.call(router, {:register_many, options}) end)

  @doc false
  def bind(%Sender{} = sender), do: call(sender, {:bind, self()})
  @doc false
  def close(%Sender{} = sender), do: call(sender, :close)

  @doc false
  def scope(opts, fun) do
    case Keyword.get(opts, :messaging) do
      %Sender{} = sender ->
        run_scope(sender, opts, fun)

      router when is_pid(router) ->
        open_scope(router, opts, fun)

      nil ->
        {:ok, router} = start_link(owner: self())

        try do
          open_scope(router, opts, fun)
        after
          if Process.alive?(router), do: GenServer.stop(router)
        end

      other ->
        {:error, {:invalid_option, :messaging, other}}
    end
  end

  defp open_scope(router, opts, fun) do
    with {:ok, sender} <- register(router, input: opts[:input], label: "root"),
         do: run_scope(sender, opts, fun)
  end

  defp run_scope(sender, opts, fun) do
    with {:ok, input} <- bind(sender) do
      try do
        fun.(opts |> Keyword.put(:messaging, sender) |> Keyword.put(:input, input))
      after
        close(sender)
      end
    end
  end

  defp envelope(opts, sender) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:text, :delivery, :idempotency_key, :in_reply_to] == [] do
      message = %{
        text: opts[:text],
        mode: Keyword.get(opts, :delivery, :steer),
        sender: sender,
        idempotency_key: opts[:idempotency_key],
        in_reply_to: opts[:in_reply_to]
      }

      if is_binary(message.text) and String.valid?(message.text) and
           byte_size(message.text) in 1..64_000 and message.mode in [:steer, :follow_up] and
           Enum.all?([message.idempotency_key, message.in_reply_to], &optional_id?/1),
         do: {:ok, message},
         else: {:error, :invalid_message}
    else
      {:error, :invalid_message}
    end
  end

  defp envelope(_, _), do: {:error, :invalid_message}
  defp optional_id?(nil), do: true
  defp optional_id?(id), do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id)

  defp call(%Sender{router: router} = sender, request),
    do: safe(fn -> GenServer.call(router, {sender, request}) end)

  defp call(router, request) when is_pid(router),
    do: safe(fn -> GenServer.call(router, {:host, request}) end)

  defp call(_, _), do: {:error, :invalid_sender}

  defp safe(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :messaging_unavailable}
  end

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :owner, self())
    {:ok, %{entries: %{}, monitors: %{}, owner: Process.monitor(owner)}}
  end

  @impl true
  def handle_call({:register_many, options}, _from, state) do
    if map_size(state.entries) + length(options) > 256 do
      {:reply, {:error, :agent_capacity}, state}
    else
      {senders, state} =
        Enum.map_reduce(options, state, fn opts, acc ->
          id = "agent-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

          {:ok, input} =
            case opts[:input] do
              nil -> Alto.Input.start_link()
              pid -> {:ok, pid}
            end

          sender = %Sender{router: self(), id: id, token: make_ref()}

          entry = %{
            sender: sender,
            input: input,
            status: :pending,
            label: opts[:label],
            parent: opts[:parent],
            owned_input: is_nil(opts[:input]),
            supported: Keyword.get(opts, :supported, true)
          }

          {sender, put_in(acc.entries[id], entry)}
        end)

      {:reply, {:ok, senders}, state}
    end
  end

  def handle_call({authority, request}, _from, state) do
    case authenticate(authority, state) do
      {:ok, sender} -> dispatch(request, sender, state)
      error -> {:reply, error, state}
    end
  end

  defp authenticate(:host, _), do: {:ok, %{kind: :user}}

  defp authenticate(%Sender{id: id} = sender, state) do
    case state.entries[id] do
      %{sender: ^sender, status: status} when status != :closed ->
        {:ok, %{kind: :agent, id: id}}

      _ ->
        {:error, :invalid_sender}
    end
  end

  defp authenticate(_, _), do: {:error, :invalid_sender}

  defp dispatch({:bind, pid}, %{kind: :agent, id: id}, state) do
    case state.entries[id] do
      %{status: :pending} = entry ->
        ref = Process.monitor(pid)

        state = %{
          state
          | entries: Map.put(state.entries, id, %{entry | status: :running}),
            monitors: Map.put(state.monitors, ref, id)
        }

        {:reply, {:ok, entry.input}, state}

      _ ->
        {:reply, {:error, :agent_in_use}, state}
    end
  end

  defp dispatch(:close, %{kind: :agent, id: id}, state),
    do: {:reply, :ok, close_entry(state, id)}

  defp dispatch(:list, sender, state) do
    agents =
      Enum.map(state.entries, fn {id, entry} ->
        %{
          agent_id: id,
          label: entry.label,
          parent: entry.parent,
          status: entry.status,
          messaging: entry.supported,
          self: sender[:id] == id
        }
      end)
      |> Enum.sort_by(& &1.agent_id)

    {:reply, {:ok, agents}, state}
  end

  defp dispatch({:send, id, message}, sender, state) do
    reply =
      case state.entries[id] do
        nil ->
          {:error, :unknown_agent}

        %{supported: false} ->
          {:error, :messaging_unsupported}

        %{input: input, status: status} ->
          message = Map.merge(message, %{sender: sender, recipient: id})

          if status == :closed,
            do: safe(fn -> Alto.Input.duplicate(input, message) end),
            else: safe(fn -> Alto.Input.enqueue(input, message) end)
      end

    {:reply, reply, state}
  end

  defp dispatch(_, _, state), do: {:reply, {:error, :invalid_message}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} -> {:noreply, state}
      {id, monitors} -> {:noreply, close_entry(%{state | monitors: monitors}, id)}
    end
  end

  @impl true
  def terminate(_, state) do
    Enum.each(state.entries, fn {_, entry} ->
      if entry.owned_input and Process.alive?(entry.input), do: GenServer.stop(entry.input)
    end)
  end

  defp close_entry(state, id) do
    {removed, kept} = Enum.split_with(state.monitors, fn {_, agent} -> agent == id end)
    Enum.each(removed, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)

    %{
      state
      | entries: Map.update!(state.entries, id, &%{&1 | status: :closed}),
        monitors: Map.new(kept)
    }
  end
end
