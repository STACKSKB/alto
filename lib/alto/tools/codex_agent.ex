defmodule Alto.Tools.CodexAgent do
  @moduledoc """
  Read-only Codex App Server execution owned by a supervised tool invocation.

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
  def run(%{task: task, model: model}, context, opts) do
    with_client(context, opts, fn client, guardian ->
      with :ok <- Client.subscribe(client),
           {:ok, turn} <-
             Backend.start_turn(client, nil, task,
               cwd: context.cwd,
               model: model,
               effort: Keyword.get(opts, :effort),
               approval: :read_only,
               dynamic_tools: dynamic_tools(context)
             ) do
        send(guardian, {:turn, turn})

        await(
          client,
          Map.merge(turn, %{
            monitor: Process.monitor(client),
            context: context,
            opts: Keyword.merge(opts, model: model, cwd: context.cwd, approval: :read_only),
            guardian: guardian,
            deliveries: [],
            calls: %{}
          }),
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
    do: with_client(context, opts, fn client, _ -> Backend.models(client) end)

  defp with_client(context, opts, fun) do
    client_opts =
      opts |> Keyword.take([:command, :args, :env, :startup_timeout, :request_timeout])

    client_opts =
      Keyword.merge(client_opts, cwd: context.cwd, instance: make_ref(), experimental_api: true)

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

      {:codex_request, ^client, id, "item/tool/call", params} ->
        turn = dynamic_call(client, id, params, turn)
        await(client, turn, messages, usage, limit)

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
    after
      20 ->
        with {:ok, turn} <- deliver(client, turn, [:steer], :steer),
             do: await(client, turn, messages, usage, limit)
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
         client,
         %{turn_id: id} = turn,
         messages,
         usage,
         limit
       ) do
    if status == "completed" do
      case deliver(client, turn, [:steer, :follow_up], :next_turn) do
        {:ok, %{turn_id: ^id}} ->
          {:ok,
           %{
             backend: "codex",
             thread_id: turn.thread_id,
             turn_id: id,
             messages: messages,
             usage: usage,
             model_request_accounting: "external",
             deliveries: turn.deliveries
           }}

        {:ok, next} ->
          await(client, next, messages, usage, limit)

        error ->
          error
      end
    else
      {:unknown, {:codex_turn_failed, status, result["error"]}}
    end
  end

  defp event(_, _, client, turn, messages, usage, limit),
    do: await(client, turn, messages, usage, limit)

  defp dynamic_tools(context) do
    Enum.map(context.messaging_tools || [], fn name ->
      module = messaging_module(name)
      schema = module.schema([])
      %{name: name, description: schema.description, inputSchema: schema.parameters}
    end)
  end

  defp messaging_module("send_message"), do: Alto.Tools.SendMessage
  defp messaging_module("list_agents"), do: Alto.Tools.ListAgents

  defp dynamic_call(client, id, params, turn) do
    name = params["tool"]
    call_id = params["callId"]
    args = params["arguments"]

    valid =
      params["threadId"] == turn.thread_id and params["turnId"] == turn.turn_id and
        is_nil(params["namespace"]) and name in (turn.context.messaging_tools || []) and
        is_binary(call_id) and byte_size(call_id) in 1..256 and is_map(args) and
        :erlang.external_size(args) <= 66_000

    if valid do
      fingerprint = {name, args}

      case turn.calls[call_id] do
        {^fingerprint, result} ->
          Client.respond(client, id, result)
          turn

        nil when map_size(turn.calls) < 256 ->
          outcome =
            with :ok <- Alto.Runner.Budget.take(turn.context.budget),
                 do: messaging_module(name).run(args, turn.context, [])

          {success, value} =
            case outcome do
              {:ok, value} -> {true, value}
              {:error, reason} -> {false, %{error: inspect(reason, limit: 10)}}
            end

          result = %{
            success: success,
            contentItems: [
              %{type: "inputText", text: JSON.encode!(Alto.Protocol.encode_term(value))}
            ]
          }

          Client.respond(client, id, result)
          %{turn | calls: Map.put(turn.calls, call_id, {fingerprint, result})}

        _ ->
          Client.reject(client, id, -32602, "Conflicting or excessive dynamic tool calls")
          turn
      end
    else
      Client.reject(client, id, -32602, "Uncorrelated or unauthorized messaging tool call")
      turn
    end
  end

  defp deliver(_client, %{context: %{input: nil}} = turn, _modes, _kind), do: {:ok, turn}

  defp deliver(client, turn, modes, kind) do
    context = turn.context

    case Alto.Input.read(context.input, context.input_reader, modes) do
      nil ->
        {:ok, turn}

      {:error, reason} ->
        {:unknown, {:codex_input_failed, reason}}

      entry ->
        # Fence delivery before network I/O. A crash or timeout leaves an explicit
        # unknown receipt; restore must never automatically resend this message.
        with :ok <- Alto.Runner.Budget.take(context.budget),
             :ok <-
               Alto.Input.acknowledge(
                 context.input,
                 context.input_reader,
                 entry.message_id,
                 :unknown
               ),
             {:ok, response} <- send_input(client, turn, entry, kind),
             {:ok, next} <- delivered_turn(turn, response, kind),
             _ <- send(turn.guardian, {:turn, next}),
             :ok <- Alto.Input.settle(context.input, context.input_reader, entry.message_id) do
          {:ok,
           %{
             next
             | deliveries:
                 turn.deliveries ++
                   [%{message_id: entry.message_id, sender: entry.sender, status: :delivered}]
           }}
        else
          {:error, reason} -> {:unknown, {:codex_message_delivery, entry.message_id, reason}}
        end
    end
  end

  defp send_input(client, turn, entry, :steer) do
    Client.request(
      client,
      "turn/steer",
      %{
        "threadId" => turn.thread_id,
        "expectedTurnId" => turn.turn_id,
        "input" => [%{"type" => "text", "text" => Alto.Messaging.message_text(entry)}]
      },
      Keyword.get(turn.opts, :request_timeout, 5_000)
    )
  end

  defp send_input(client, turn, entry, :next_turn) do
    Client.request(
      client,
      "turn/start",
      Backend.turn_params(turn.thread_id, Alto.Messaging.message_text(entry), turn.opts),
      Keyword.get(turn.opts, :request_timeout, 5_000)
    )
  end

  defp delivered_turn(turn, %{"turnId" => id}, :steer) when id == turn.turn_id, do: {:ok, turn}

  defp delivered_turn(turn, %{"turn" => %{"id" => id}}, :next_turn) when is_binary(id),
    do: {:ok, %{turn | turn_id: id}}

  defp delivered_turn(_, _, _), do: {:error, :invalid_codex_delivery_response}
end
