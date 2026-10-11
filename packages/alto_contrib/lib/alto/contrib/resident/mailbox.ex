defmodule Alto.Contrib.Resident.Mailbox do
  @moduledoc "Addressed team messages backed by Alto's bounded durable queue."
  alias Alto.Queue
  alias Alto.Contrib.Resident.Service

  def child(config, name) do
    settings = config.mailbox

    Supervisor.child_spec(
      {Queue,
       name: queue(name),
       id: "team-messages",
       dir: Path.join(config.state_dir, "queues"),
       max_records: settings[:max_messages],
       auto_compact: settings[:auto_compact],
       max_completed: settings[:max_completed],
       max_payload_bytes: 64_000,
       max_log_bytes: settings[:max_log_bytes],
       lease_ms: settings[:lease_ms]},
      id: __MODULE__
    )
  end

  def queue(name \\ Service), do: Service.component(name, :mailbox)

  @doc "Local operator commands; model tools do not receive this cross-address access."
  def commands(name) do
    Map.new(~w(list get cancel compact), fn action ->
      {"mailbox." <> action, fn args -> inspect_or_cancel(queue(name), action, args) end}
    end)
  end

  defp inspect_or_cancel(queue, "compact", args) when is_map(args) and map_size(args) == 0,
    do: Queue.request(queue, :compact, :infinity)

  defp inspect_or_cancel(queue, "list", %{"root" => root} = args) do
    cursor = Map.get(args, "cursor", 0)

    with true <- text?(root, 200) and is_integer(cursor) and cursor >= 0,
         {:ok, page} <- Queue.request(queue, {:snapshot_page, cursor, 10}) do
      records = Enum.filter(page.records, &(&1.payload["root"] == root))
      {:ok, %{messages: records, next_cursor: page.next_cursor}}
    else
      false -> {:error, :invalid_mailbox_query}
      {:error, _} = error -> error
    end
  end

  defp inspect_or_cancel(queue, action, %{"root" => root, "key" => key})
       when action in ["get", "cancel"] do
    with true <- text?(root, 200) and text?(key, 100),
         {:ok, record} <- Queue.request(queue, {:lookup, key}),
         true <- record.payload["root"] == root do
      case action do
        "get" ->
          {:ok, %{message: record}}

        "cancel" ->
          with :ok <- Queue.request(queue, {:cancel_pending, key}),
               do: {:ok, %{key: key, status: "cancelled"}}
      end
    else
      false -> {:error, :invalid_mailbox_query}
      {:error, _} = error -> error
    end
  end

  defp inspect_or_cancel(_queue, _action, _args), do: {:error, :invalid_mailbox_query}

  @doc "Use the host's execution-tree identity; arguments cannot choose a sender or root."
  def execute(%{agent_identity: identity}, arguments, opts \\ []) do
    with :ok <- validate_identity(identity),
         true <- is_map(arguments) do
      dispatch(Keyword.get(opts, :queue, queue()), identity, arguments)
    else
      false -> {:error, :invalid_mailbox_arguments}
      {:error, _} = error -> error
    end
  end

  defp dispatch(queue, identity, %{"action" => "send"} = args) do
    with :ok <- only(args, ~w(action id to body)),
         true <- text?(args["id"], 100) and text?(args["body"], 32_000),
         true <- address?(args["to"]) do
      key = message_key(identity, args["id"])

      payload = %{
        "v" => 1,
        "root" => identity.root_run_id,
        "from" => identity.path,
        "to" => args["to"],
        "id" => args["id"],
        "body" => args["body"],
        "created_at_ms" => System.system_time(:millisecond)
      }

      with true <- byte_size(JSON.encode!(payload)) <= 32_000 do
        case Queue.request(queue, {:admit, key, payload, []}) do
          {:ok, _} ->
            {:ok, %{key: key, duplicate: false, identity: identity}}

          {:error, :duplicate} ->
            {:ok, %{key: key, duplicate: true, identity: identity}}

          {:error, {:key_claimed, ^key}} ->
            {:ok, %{key: key, duplicate: true, identity: identity}}

          {:error, _} = error ->
            error
        end
      else
        false -> {:error, :message_too_large}
      end
    else
      false -> {:error, :invalid_message}
      {:error, _} = error -> error
    end
  end

  defp dispatch(queue, identity, %{"action" => "receive"} = args) do
    count = Map.get(args, "count", 5)

    with :ok <- only(args, ~w(action count)),
         true <- is_integer(count) and count in 1..10,
         {:ok, messages} <- Queue.request(queue, {:claim, count, nil, 48_000, selector(identity)}) do
      {:ok, %{identity: identity, messages: messages}}
    else
      false -> {:error, :invalid_receive_count}
      {:error, _} = error -> error
    end
  end

  defp dispatch(queue, identity, %{"action" => action} = args)
       when action in ["ack", "release"] do
    with :ok <- only(args, ~w(action key claim_id)),
         true <- text?(args["key"], 100) and text?(args["claim_id"], 100),
         {:ok, record} <- Queue.request(queue, {:lookup, args["key"]}),
         true <- matches?(record.payload, selector(identity)),
         true <- record.claim_id == args["claim_id"],
         :ok <- settle(queue, action, args["claim_id"]) do
      {:ok, %{key: args["key"], action: action}}
    else
      false -> {:error, :mailbox_claim_mismatch}
      {:error, _} = error -> error
    end
  end

  defp dispatch(_queue, _identity, _args), do: {:error, :invalid_mailbox_action}

  defp settle(queue, "ack", claim), do: Queue.request(queue, {:settle, claim, :ack, []})
  defp settle(queue, "release", claim), do: Queue.request(queue, {:settle, claim, :release, []})

  defp selector(identity), do: %{"root" => identity.root_run_id, "to" => identity.path}
  defp matches?(payload, selector), do: Enum.all?(selector, fn {k, v} -> payload[k] == v end)

  defp message_key(identity, id) do
    :crypto.hash(:sha256, :erlang.term_to_binary([identity.root_run_id, identity.path, id]))
    |> Base.encode16(case: :lower)
  end

  defp validate_identity(%{root_run_id: root, path: path}) do
    if text?(root, 200) and address?(path), do: :ok, else: {:error, :invalid_mailbox_identity}
  end

  defp validate_identity(_), do: {:error, :mailbox_identity_required}

  # Lists avoid aliases between the lead ([]) and a worker named "lead" (["lead"]).
  defp address?(path),
    do: is_list(path) and length(path) <= 16 and Enum.all?(path, &text?(&1, 100))

  defp text?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp only(args, keys) do
    if Map.keys(args) -- keys == [], do: :ok, else: {:error, :invalid_mailbox_arguments}
  end
end
