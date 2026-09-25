defmodule Alto.Tools.CodexAgent do
  @moduledoc """
  One read-only Codex App Server turn, owned by a supervised tool invocation.

  App Server owns its tools and internal model calls. Alto bounds the invocation's
  lifetime and output, but cannot meter Codex's internal calls against its native
  model-request budget. Register this capability explicitly and keep it hidden
  from the parent model when using it through a rule-loop child.
  """
  use Alto.Tool, name: :codex_agent, execution_mode: :exclusive, approval: :required
  alias Alto.Codex.{AppServer.Client, Backend}

  @impl true
  def schema(_opts) do
    Alto.Tool.object_schema(
      "Run a read-only Codex agent task with an optional model selection.",
      %{task: %{type: "string"}, model: %{type: "string"}},
      ["task"]
    )
  end

  @impl true
  def prepare(%{"task" => task} = arguments, _context, opts)
      when is_binary(task) and byte_size(task) in 1..64_000 do
    model = Map.get(arguments, "model", Keyword.get(opts, :model))

    if Map.keys(arguments) -- ["task", "model"] == [] and
         (is_nil(model) or (is_binary(model) and byte_size(model) in 1..256)),
       do:
         {:ok, %{task: task, model: model},
          %{
            backend: "codex",
            model: model,
            sandbox: "read-only",
            internal_model_budget: "external"
          }},
       else: {:error, :invalid_agent_task}
  end

  def prepare(_, _, _), do: {:error, :invalid_agent_task}

  @impl true
  def run_prepared(%{task: task, model: model}, context, opts) do
    with_client(context, opts, fn client, guardian ->
      with :ok <- Client.subscribe(client),
           {:ok, turn} <-
             Backend.start_turn(client, nil, task,
               cwd: context.cwd,
               model: model,
               effort: Keyword.get(opts, :effort),
               approval: :read_only
             ) do
        send(guardian, {:turn, turn})

        await(
          client,
          Map.put(turn, :monitor, Process.monitor(client)),
          %{},
          nil,
          Keyword.get(opts, :max_output_bytes, 48_000)
        )
      else
        {:error, reason} -> {:unknown, reason}
      end
    end)
  end

  @doc false
  def models(context, opts),
    do: with_client(context, opts, fn client, _ -> models(client, nil, [], 100) end)

  defp models(_client, _cursor, _entries, 0), do: {:error, :codex_model_page_limit}

  defp models(client, cursor, entries, remaining) do
    with {:ok, %{"data" => models} = result} <-
           Client.request(client, "model/list", %{
             "limit" => 100,
             "cursor" => cursor,
             "includeHidden" => false
           }) do
      entries =
        entries ++ Enum.map(models, &%{id: &1["model"] || &1["id"], name: &1["displayName"]})

      case result["nextCursor"] do
        nil -> {:ok, entries}
        next -> models(client, next, entries, remaining - 1)
      end
    end
  end

  defp with_client(context, opts, fun) do
    client_opts =
      opts |> Keyword.take([:command, :args, :env, :startup_timeout, :request_timeout])

    client_opts = Keyword.merge(client_opts, cwd: context.cwd, instance: make_ref())
    # Own startup as well as the turn so cancellation during the handshake
    # cannot leave a private App Server behind.
    owner = self()
    guardian = spawn(fn -> connect(owner, client_opts) end)
    monitor = Process.monitor(guardian)

    receive do
      {:codex_client, ^guardian, {:ok, client}} ->
        try do
          fun.(client, guardian)
        after
          send(guardian, :close)
          receive do: ({:DOWN, ^monitor, :process, _, _} -> :ok)
        end

      {:codex_client, ^guardian, {:error, reason}} ->
        Process.demonitor(monitor, [:flush])
        {:error, reason}

      {:DOWN, ^monitor, :process, _, reason} ->
        {:error, {:codex_start_failed, reason}}
    end
  end

  defp connect(owner, opts) do
    monitor = Process.monitor(owner)
    result = Client.ensure_started(opts)
    send(owner, {:codex_client, self(), result})

    case result do
      {:ok, client} -> guard(client, monitor, nil)
      {:error, _} -> :ok
    end
  end

  defp guard(client, monitor, turn) do
    receive do
      {:turn, turn} -> guard(client, monitor, turn)
      :close -> close(client, turn)
      {:DOWN, ^monitor, :process, _, _} -> close(client, turn)
    end
  end

  defp close(client, turn) do
    if turn do
      Client.request(
        client,
        "turn/interrupt",
        %{"threadId" => turn.thread_id, "turnId" => turn.turn_id},
        1_000
      )
    end

    GenServer.stop(client, :normal, 1_000)
  catch
    :exit, _ -> Process.exit(client, :kill)
  end

  defp await(client, turn, messages, usage, limit) do
    monitor = turn.monitor

    receive do
      {:codex_notification, ^client, method, %{"threadId" => thread} = params}
      when thread == turn.thread_id ->
        event(method, params, client, turn, messages, usage, limit)

      {:codex_request, ^client, id, _method, _params} ->
        Client.reject(
          client,
          id,
          -32601,
          "Read-only delegated agents cannot request additional capabilities"
        )

        await(client, turn, messages, usage, limit)

      {:codex_notification, ^client, _, _} ->
        await(client, turn, messages, usage, limit)

      {:DOWN, ^monitor, :process, _, reason} ->
        {:unknown, {:codex_disconnected, reason}}
    end
  end

  defp event(
         "item/completed",
         %{"turnId" => id, "item" => %{"type" => "agentMessage", "id" => item, "text" => text}},
         client,
         %{turn_id: id} = turn,
         messages,
         usage,
         limit
       ) do
    messages = Map.put(messages, item, text)

    if :erlang.external_size(messages) <= limit,
      do: await(client, turn, messages, usage, limit),
      else: {:unknown, :codex_output_too_large}
  end

  defp event("thread/tokenUsage/updated", params, client, turn, messages, _usage, limit),
    do: await(client, turn, messages, get_in(params, ["tokenUsage", "total"]), limit)

  defp event(
         "turn/completed",
         %{"turn" => %{"id" => id, "status" => status} = result},
         _client,
         %{turn_id: id} = turn,
         messages,
         usage,
         _limit
       ) do
    if status == "completed" do
      {:ok,
       %{
         backend: "codex",
         thread_id: turn.thread_id,
         turn_id: id,
         messages: messages,
         usage: usage,
         model_request_accounting: "external"
       }}
    else
      {:unknown, {:codex_turn_failed, status, result["error"]}}
    end
  end

  defp event(_, _, client, turn, messages, usage, limit),
    do: await(client, turn, messages, usage, limit)
end
