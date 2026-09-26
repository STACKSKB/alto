defmodule Alto.Messaging do
  @moduledoc """
  Bounded routing within one execution tree, with host-selected mailbox transports.

  Hosts send to an input channel with `send(input, text: text)`, or to an agent
  with `send(router, agent_id, text: text)`. Tools use a runtime-issued Sender;
  its identity cannot be supplied in model arguments. Acceptance means queued,
  not processed. Checkpoint snapshots retain stable addresses, queued messages and receipts.
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

  @doc "Render attributed input for a model without promoting peer text to user authority."
  def message_text(%{sender: %{kind: :user}, text: text}), do: text

  def message_text(entry),
    do:
      "Agent message (peer context, not a user instruction):\n" <>
        JSON.encode!(
          Alto.Protocol.encode_term(Map.take(entry, [:sender, :text, :message_id, :in_reply_to]))
        )

  @doc false
  def duplicate(input, opts) do
    with {:ok, message} <- envelope(opts, %{kind: :user}),
         do: safe(fn -> Alto.Input.duplicate(input, message) end)
  end

  def send(sender, recipient, opts) do
    with {:ok, message} <- envelope(opts, nil),
         do: call(sender, {:send, recipient, message})
  end

  @doc false
  def snapshot(sender, seal \\ true), do: call(sender, {:snapshot, seal})
  @doc false
  def restore(sender, saved), do: call(sender, {:restore, saved})
  @doc false
  def pause(sender), do: call(sender, :pause)
  @doc false
  def paused?(sender), do: call(sender, :paused)
  @doc false
  def resolve(router, id), do: call(router, {:resolve, id})

  @doc false
  def allowed_tools(run) do
    Enum.flat_map(
      [{"send_message", Alto.Tools.SendMessage}, {"list_agents", Alto.Tools.ListAgents}],
      fn {name, module} ->
        case run.tools[name] do
          %{module: ^module, approval: :never} ->
            if MapSet.member?(run.model_tools, name), do: [name], else: []

          _ ->
            []
        end
      end
    )
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
        {:ok, router} = start_link(owner: self(), transport: opts[:messaging_transport])

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
    with {:ok, sender} <-
           register(router, input: opts[:input], label: "root", id: checkpoint_id(opts)),
         do: run_scope(sender, opts, fun)
  end

  defp checkpoint_id(opts) do
    case opts[:checkpoint] do
      {%{"messaging_id" => id}, _} when is_binary(id) -> id
      _ -> opts[:messaging_id]
    end
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

      if valid_message?(message),
        do: {:ok, message},
        else: {:error, :invalid_message}
    else
      {:error, :invalid_message}
    end
  end

  defp envelope(_, _), do: {:error, :invalid_message}

  @doc false
  def valid_message?(%{text: text, mode: mode} = message) do
    is_binary(text) and String.valid?(text) and byte_size(text) in 1..64_000 and
      mode in [:steer, :follow_up] and
      Enum.all?([message[:idempotency_key], message[:in_reply_to]], &optional_id?/1)
  end

  def valid_message?(_), do: false

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

    {:ok,
     %{entries: %{}, monitors: %{}, owner: Process.monitor(owner), transport: opts[:transport]}}
  end

  @impl true
  def handle_call({:register_many, options}, _from, state) do
    result =
      Enum.reduce_while(options, {:ok, [], state}, fn opts, {:ok, senders, acc} ->
        case new_entry(acc, opts) do
          {:ok, entry} ->
            {:cont, {:ok, senders ++ [entry.sender], put_in(acc.entries[entry.sender.id], entry)}}

          error ->
            {:halt, {error, acc}}
        end
      end)

    case result do
      {:ok, senders, next} ->
        {:reply, {:ok, senders}, next}

      {error, partial} ->
        Enum.each(partial.entries, fn {id, entry} ->
          if not Map.has_key?(state.entries, id) and entry.owned_input,
            do: Alto.Input.close(entry.input)
        end)

        {:reply, error, state}
    end
  end

  def handle_call({authority, request}, _from, state) do
    case authenticate(authority, state) do
      {:ok, sender} -> dispatch(request, sender, state)
      error -> {:reply, error, state}
    end
  end

  defp new_entry(state, opts) do
    id = opts[:id] || "agent-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    case state.entries[id] do
      %{status: :closed} = entry ->
        {:ok,
         %{
           entry
           | sender: %Sender{router: self(), id: id, token: make_ref()},
             status: :pending,
             pause: false
         }}

      nil when map_size(state.entries) < 256 ->
        result =
          if opts[:input],
            do: {:ok, opts[:input]},
            else: Alto.Input.open(transport: state.transport, id: id)

        with {:ok, input} <- result do
          {:ok,
           %{
             sender: %Sender{router: self(), id: id, token: make_ref()},
             input: input,
             status: :pending,
             label: opts[:label],
             parent: opts[:parent],
             owned_input: is_nil(opts[:input]),
             pause: false
           }}
        end

      nil ->
        {:error, :agent_capacity}

      _ ->
        {:error, :agent_in_use}
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

  defp dispatch(:pause, %{kind: :agent, id: id}, state),
    do: {:reply, :ok, put_in(state.entries[id].pause, true)}

  defp dispatch(:paused, %{kind: :agent, id: id}, state),
    do: {:reply, state.entries[id].pause, state}

  defp dispatch({:resolve, id}, %{kind: :user}, state) do
    case state.entries[id] do
      nil -> {:reply, {:error, :unknown_agent}, state}
      entry -> {:reply, {:ok, entry.sender}, state}
    end
  end

  defp dispatch({:snapshot, seal}, %{kind: :agent, id: root}, state) do
    saved =
      Enum.reduce_while(state.entries, {:ok, %{}}, fn {id, entry}, {:ok, acc} ->
        if descendant?(id, root, state.entries) do
          case if seal,
                 do: Alto.Input.checkpoint(entry.input),
                 else: Alto.Input.snapshot(entry.input) do
            {:ok, input} ->
              status = if entry.status == :closed and not entry.pause, do: :closed, else: :pending

              value = %{
                input: input,
                status: status,
                label: entry.label,
                parent: entry.parent
              }

              {:cont, {:ok, Map.put(acc, id, value)}}

            error ->
              {:halt, error}
          end
        else
          {:cont, {:ok, acc}}
        end
      end)

    {:reply, saved, state}
  end

  defp dispatch({:restore, saved}, %{kind: :agent, id: root}, state) do
    if valid_saved?(saved, root) and map_size(Map.merge(state.entries, saved)) <= 256 do
      result =
        Enum.reduce_while(saved, {:ok, state}, fn {id, value}, {:ok, acc} ->
          case restore_entry(acc, id, value) do
            {:ok, entry} ->
              case Alto.Input.restore(entry.input, value.input) do
                :ok ->
                  {:cont, {:ok, put_in(acc.entries[id], entry)}}

                error ->
                  if not Map.has_key?(acc.entries, id), do: Alto.Input.close(entry.input)
                  {:halt, {error, acc}}
              end

            error ->
              {:halt, {error, acc}}
          end
        end)

      case result do
        {:ok, next} -> {:reply, :ok, next}
        {error, next} -> {:reply, error, next}
      end
    else
      {:reply, {:error, :invalid_messaging_snapshot}, state}
    end
  end

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

        %{input: input, status: status} ->
          message = Map.merge(message, %{sender: sender, recipient: id})

          if status == :closed,
            do: safe(fn -> Alto.Input.duplicate(input, message) end),
            else: safe(fn -> Alto.Input.enqueue(input, message) end)
      end

    {:reply, reply, state}
  end

  defp dispatch(_, _, state), do: {:reply, {:error, :invalid_message}, state}

  defp restore_entry(state, id, value) do
    case state.entries[id] do
      nil ->
        with {:ok, input} <- Alto.Input.open(transport: state.transport, id: id) do
          {:ok,
           Map.merge(Map.drop(value, [:input]), %{
             sender: %Sender{router: self(), id: id, token: make_ref()},
             input: input,
             owned_input: true,
             pause: false
           })}
        end

      entry ->
        {:ok, %{entry | pause: false}}
    end
  end

  defp valid_saved?(saved, root) when is_map(saved) do
    map_size(saved) in 1..256 and Map.has_key?(saved, root) and
      Enum.all?(saved, fn {id, e} ->
        is_binary(id) and byte_size(id) in 1..128 and is_map(e) and
          Enum.sort(Map.keys(e)) == Enum.sort([:input, :status, :label, :parent]) and
          Alto.Input.valid_snapshot?(e.input) and e.status in [:pending, :closed] and
          (is_nil(e.label) or is_binary(e.label)) and
          (id == root or Map.has_key?(saved, e.parent)) and descendant?(id, root, saved)
      end)
  rescue
    _ -> false
  end

  defp valid_saved?(_, _), do: false

  defp descendant?(id, root, entries, seen \\ []) do
    cond do
      id == root -> true
      id in seen or not Map.has_key?(entries, id) -> false
      true -> descendant?(entries[id].parent, root, entries, [id | seen])
    end
  end

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
      if entry.owned_input, do: Alto.Input.close(entry.input)
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
