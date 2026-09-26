defmodule Alto.Tools.CodexAgentTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "alto-codex-agent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    server = Path.join(root, "server.py")
    log = Path.join(root, "requests.jsonl")

    File.write!(server, ~S"""
    import json, sys
    turn_count = 0
    def emit(value):
        print(json.dumps(value), flush=True)
    for line in sys.stdin:
        msg = json.loads(line)
        with open(sys.argv[1], 'a') as log:
            log.write(line)
        method = msg.get('method')
        ident = msg.get('id')
        if method == 'initialize':
            emit({'id': ident, 'result': {'serverInfo': {'name': 'fake'}}})
        elif method == 'model/list':
            if msg['params'].get('cursor'):
                emit({'id': ident, 'result': {'data': [{'id': 'next', 'model': 'second-model', 'displayName': 'Second'}], 'nextCursor': None}})
            else:
                emit({'id': ident, 'result': {'data': [{'id': 'first', 'model': 'first-model', 'displayName': 'First'}], 'nextCursor': 'page-2'}})
        elif method == 'thread/start':
            emit({'id': ident, 'result': {'thread': {'id': 'thread-1'}}})
        elif method == 'turn/start':
            turn_count += 1
            turn_id = 'turn-' + str(turn_count)
            emit({'id': ident, 'result': {'turn': {'id': turn_id}}})
            task = msg['params']['input'][0]['text']
            if task == 'disconnect':
                sys.exit(0)
            if task.startswith('send:'):
                target = task.split(':', 1)[1]
                params = {'threadId': 'thread-1', 'turnId': turn_id, 'callId': 'send-one', 'tool': 'send_message', 'arguments': {'to': target, 'text': 'peer reply'}}
                emit({'id': 'send-first', 'method': 'item/tool/call', 'params': params})
                emit({'id': 'send-duplicate', 'method': 'item/tool/call', 'params': params})
                emit({'id': 'bad-turn', 'method': 'item/tool/call', 'params': dict(params, turnId='wrong')})
            if task in ['hang', 'live', 'timeout', 'follow']:
                continue
            emit({'method': 'item/completed', 'params': {'threadId': 'unrelated', 'turnId': 'turn-1', 'item': {'type': 'agentMessage', 'id': 'other', 'text': 'ignore me'}}})
            emit({'method': 'item/completed', 'params': {'threadId': 'thread-1', 'turnId': 'old-turn', 'item': {'type': 'agentMessage', 'id': 'old', 'text': 'ignore me'}}})
            emit({'id': 'permission', 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'thread-1', 'turnId': 'turn-1'}})
            text = 'x' * 1000 if task == 'large' else 'Review complete'
            emit({'method': 'item/completed', 'params': {'threadId': 'thread-1', 'turnId': 'turn-1', 'item': {'type': 'agentMessage', 'id': 'answer', 'text': text}}})
            emit({'method': 'thread/tokenUsage/updated', 'params': {'threadId': 'thread-1', 'tokenUsage': {'total': {'inputTokens': 12, 'outputTokens': 4}}}})
            emit({'method': 'turn/completed', 'params': {'threadId': 'thread-1', 'turn': {'id': turn_id, 'status': 'failed' if task == 'fail' else 'completed'}}})
        elif method == 'turn/steer':
            if msg['params']['input'][0]['text'] == 'timeout':
                continue
            emit({'id': ident, 'result': {'turnId': 'turn-1'}})
            emit({'id': 'dynamic', 'method': 'item/tool/call', 'params': {'threadId': 'thread-1', 'turnId': 'turn-1', 'callId': 'call-one', 'tool': 'list_agents', 'arguments': {}}})
            emit({'method': 'turn/completed', 'params': {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'completed'}}})
        elif method == 'turn/interrupt':
            emit({'id': ident, 'result': {}})
    """)

    on_exit(fn -> File.rm_rf!(root) end)

    tool =
      {Alto.Tools.CodexAgent,
       command: System.find_executable("python3"), args: [server, log], startup_timeout: 5_000}

    %{root: root, log: log, tool: tool}
  end

  defp opts(context, extra \\ []) do
    Keyword.merge(
      [
        cwd: context.root,
        tools: [context.tool],
        loop: Alto.rule_loop(steps: ["codex_agent"]),
        approval: Alto.Approvals.AllowAll
      ],
      extra
    )
  end

  defp requests(log) do
    case File.read(log) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      _ -> []
    end
  end

  defp wait_for(log, method, attempts \\ 500)
  defp wait_for(_, _, 0), do: flunk("App Server request never arrived")

  defp wait_for(log, method, attempts) do
    if Enum.any?(requests(log), &(&1["method"] == method)) do
      :ok
    else
      Process.sleep(10)
      wait_for(log, method, attempts - 1)
    end
  end

  test "live steering uses the current turn and exposes only authorized messaging tools",
       context do
    {:ok, input} = Alto.Input.start_link()

    {:ok, handle} =
      Alto.start(
        %{"task" => "live"},
        opts(context, input: input, tools: [context.tool, Alto.Tools.ListAgents])
      )

    wait_for(context.log, "turn/start")
    {:ok, receipt} = Alto.Messaging.send(input, text: "use the new plan")
    assert {:ok, result} = Alto.await(handle)
    [value] = result.output
    assert [%{message_id: id, status: :delivered}] = value.deliveries
    assert id == receipt.message_id
    assert {:ok, %{status: :delivered}} = Alto.Input.receipt(input, id)
    assert Alto.Input.list(input) == []
    sent = requests(context.log)
    steer = Enum.find(sent, &(&1["method"] == "turn/steer"))
    assert steer["params"]["expectedTurnId"] == "turn-1"
    assert steer["params"]["input"] == [%{"type" => "text", "text" => "use the new plan"}]

    assert [%{"name" => "list_agents"}] =
             Enum.find(sent, &(&1["method"] == "thread/start"))["params"]["dynamicTools"]

    assert Enum.find(sent, &(&1["id"] == "dynamic"))["result"]["success"]
  end

  test "follow-up starts a fresh turn after the active turn finishes", context do
    {:ok, input} = Alto.Input.start_link()

    {:ok, handle} =
      Alto.start(
        %{"task" => "follow", "model" => "chosen-followup"},
        opts(context,
          input: input,
          tools: [{elem(context.tool, 0), Keyword.put(elem(context.tool, 1), :effort, "high")}]
        )
      )

    wait_for(context.log, "turn/start")
    {:ok, later} = Alto.Messaging.send(input, text: "second task", delivery: :follow_up)
    Process.sleep(40)
    assert Enum.count(requests(context.log), &(&1["method"] == "turn/start")) == 1
    {:ok, _} = Alto.Messaging.send(input, text: "finish current turn")
    assert {:ok, result} = Alto.await(handle)
    assert [%{turn_id: "turn-2"}] = result.output
    turns = Enum.filter(requests(context.log), &(&1["method"] == "turn/start"))
    assert length(turns) == 2
    assert Enum.all?(turns, &(&1["params"]["model"] == "chosen-followup"))
    assert Enum.all?(turns, &(&1["params"]["effort"] == "high"))
    assert List.last(turns)["params"]["input"] == [%{"type" => "text", "text" => "second task"}]
    assert {:ok, %{status: :delivered}} = Alto.Input.receipt(input, later.message_id)
  end

  test "Codex messages have runtime provenance and duplicate tool calls send once", context do
    {:ok, router} = Alto.Messaging.start_link()
    {:ok, inbox} = Alto.Input.start_link()
    {:ok, peer} = Alto.Messaging.register(router, input: inbox, label: "peer")

    assert {:ok, _} =
             Alto.run(
               %{"task" => "send:" <> peer.id},
               opts(context, messaging: router, tools: [context.tool, Alto.Tools.SendMessage])
             )

    assert [%{text: "peer reply", sender: %{kind: :agent, id: from}}] = Alto.Input.list(inbox)
    assert from != peer.id
    sent = requests(context.log)
    first = Enum.find(sent, &(&1["id"] == "send-first"))["result"]
    assert first["success"]
    assert Enum.find(sent, &(&1["id"] == "send-duplicate"))["result"] == first
    assert Enum.find(sent, &(&1["id"] == "bad-turn"))["error"]["code"] == -32602
  end

  test "model-hidden messaging is not exposed to Codex", context do
    {:ok, router} = Alto.Messaging.start_link()
    {:ok, inbox} = Alto.Input.start_link()
    {:ok, peer} = Alto.Messaging.register(router, input: inbox)

    assert {:ok, _} =
             Alto.run(
               %{"task" => "send:" <> peer.id},
               opts(context,
                 messaging: router,
                 tools: [context.tool, Alto.Tools.SendMessage],
                 model_tools: []
               )
             )

    assert Alto.Input.list(inbox) == []
    sent = requests(context.log)
    assert Enum.find(sent, &(&1["method"] == "thread/start"))["params"]["dynamicTools"] == []
    assert Enum.find(sent, &(&1["id"] == "send-first"))["error"]["code"] == -32602
  end

  test "uncertain live delivery is retained as unknown and never resent", context do
    {:ok, input} = Alto.Input.start_link()
    {module, settings} = context.tool
    tool = {module, Keyword.put(settings, :request_timeout, 300)}
    {:ok, handle} = Alto.start(%{"task" => "timeout"}, opts(context, input: input, tools: [tool]))
    wait_for(context.log, "turn/start")
    {:ok, receipt} = Alto.Messaging.send(input, text: "timeout", idempotency_key: "once")
    assert {:error, _, _} = Alto.await(handle)
    assert {:ok, %{status: :unknown}} = Alto.Input.receipt(input, receipt.message_id)

    assert {:ok, %{status: :unknown}} =
             Alto.Messaging.send(input, text: "timeout", idempotency_key: "once")

    assert Enum.count(requests(context.log), &(&1["method"] == "turn/steer")) == 1
    {:ok, snapshot} = Alto.Input.snapshot(input)
    {:ok, restored} = Alto.Input.start_link()
    assert :ok = Alto.Input.restore(restored, snapshot)
    assert Alto.Input.list(restored) == []
    assert {:ok, %{status: :unknown}} = Alto.Input.receipt(restored, receipt.message_id)
  end

  test "read-only turn returns correlated messages, usage and rejects permission requests",
       context do
    assert {:ok, result} = Alto.run(%{"task" => "review"}, opts(context))

    assert [%{messages: %{"answer" => "Review complete"}, usage: %{"inputTokens" => 12}}] =
             result.output

    sent = requests(context.log)
    thread = Enum.find(sent, &(&1["method"] == "thread/start"))["params"]
    assert thread["sandbox"] == "read-only"
    assert thread["approvalPolicy"] == "never"
    turn = Enum.find(sent, &(&1["method"] == "turn/start"))["params"]
    assert turn["sandboxPolicy"] == %{"type" => "readOnly", "networkAccess" => false}
    assert Enum.any?(sent, &(&1["id"] == "permission" and Map.has_key?(&1, "error")))
    assert Enum.any?(sent, &(&1["method"] == "turn/interrupt"))
  end

  test "failed turns and disconnects remain uncertain", context do
    for task <- ["fail", "disconnect"] do
      assert {:error, _, result} = Alto.run(%{"task" => task}, opts(context))
      assert result.verdict == :unknown
    end
  end

  test "output bounds stop oversized agents", context do
    {module, config} = context.tool
    context = %{context | tool: {module, Keyword.put(config, :max_output_bytes, 64)}}
    assert {:error, _, result} = Alto.run(%{"task" => "large"}, opts(context))
    assert result.verdict == :unknown
    wait_for(context.log, "turn/interrupt")
  end

  test "cancellation interrupts the owned App Server even when the tool is killed", context do
    assert {:ok, handle} = Alto.start(%{"task" => "hang"}, opts(context))
    wait_for(context.log, "turn/start")
    assert :ok = Alto.cancel(handle)
    assert {:error, {:cancelled, _}, _} = Alto.await(handle, 2_000)
    wait_for(context.log, "turn/interrupt")
  end

  test "tool timeout interrupts the owned App Server", context do
    assert {:ok, handle} = Alto.start(%{"task" => "hang"}, opts(context, tool_timeout: 3_000))
    wait_for(context.log, "turn/start")
    assert {:error, _, result} = Alto.await(handle, 5_000)
    assert result.verdict == :unknown
    wait_for(context.log, "turn/interrupt")
  end

  test "discovers Codex models across pages without starting a turn", context do
    opts =
      opts(context,
        tools: [context.tool | Alto.Tools.agents()],
        loop: Alto.rule_loop(steps: ["list_agent_models"])
      )

    assert {:ok, result} = Alto.run(%{"backend" => "codex"}, opts)
    assert [%{models: models}] = result.output
    assert Enum.map(models, & &1.model) == ["first-model", "second-model"]
    refute Enum.any?(requests(context.log), &(&1["method"] == "turn/start"))
  end

  test "dynamically selected Codex model uses the ordinary subagent batch and session", context do
    args = %{
      "agents" => [
        %{"id" => "review", "backend" => "codex", "model" => "chosen-model", "task" => "review"}
      ]
    }

    opts =
      opts(context,
        tools: [context.tool | Alto.Tools.agents()],
        loop:
          Alto.rule_loop(
            steps: ["spawn_agents"],
            subagents: Alto.Subagents.bounded(max_depth: 1, sessions: :separate)
          ),
        session: :new,
        session_dir: Path.join(context.root, "sessions")
      )

    assert {:ok, result} = Alto.run(args, opts)

    assert [
             %{
               results: [
                 %{
                   id: "review",
                   status: :ok,
                   session_id: child_session,
                   output: [%{messages: %{"answer" => "Review complete"}}]
                 }
               ]
             }
           ] = result.output

    turn = Enum.find(requests(context.log), &(&1["method"] == "turn/start"))
    assert turn["params"]["model"] == "chosen-model"
    assert is_binary(child_session)
    refute child_session == result.session_id
  end
end
