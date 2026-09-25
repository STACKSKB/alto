defmodule Alto.Tools.CodexAgentTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "alto-codex-agent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    server = Path.join(root, "server.py")
    log = Path.join(root, "requests.jsonl")

    File.write!(server, ~S"""
    import json, sys
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
            emit({'id': ident, 'result': {'turn': {'id': 'turn-1'}}})
            task = msg['params']['input'][0]['text']
            if task == 'disconnect':
                sys.exit(0)
            if task == 'hang':
                continue
            emit({'method': 'item/completed', 'params': {'threadId': 'unrelated', 'turnId': 'turn-1', 'item': {'type': 'agentMessage', 'id': 'other', 'text': 'ignore me'}}})
            emit({'method': 'item/completed', 'params': {'threadId': 'thread-1', 'turnId': 'old-turn', 'item': {'type': 'agentMessage', 'id': 'old', 'text': 'ignore me'}}})
            emit({'id': 'permission', 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'thread-1', 'turnId': 'turn-1'}})
            text = 'x' * 1000 if task == 'large' else 'Review complete'
            emit({'method': 'item/completed', 'params': {'threadId': 'thread-1', 'turnId': 'turn-1', 'item': {'type': 'agentMessage', 'id': 'answer', 'text': text}}})
            emit({'method': 'thread/tokenUsage/updated', 'params': {'threadId': 'thread-1', 'tokenUsage': {'total': {'inputTokens': 12, 'outputTokens': 4}}}})
            emit({'method': 'turn/completed', 'params': {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'failed' if task == 'fail' else 'completed'}}})
        elif method == 'turn/interrupt':
            emit({'id': ident, 'result': {}})
    """)

    on_exit(fn -> File.rm_rf!(root) end)

    tool =
      {Alto.Tools.CodexAgent,
       command: System.find_executable("python3"), args: [server, log], startup_timeout: 2_000}

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

  defp wait_for(log, method, attempts \\ 200)
  defp wait_for(_, _, 0), do: flunk("App Server request never arrived")

  defp wait_for(log, method, attempts) do
    if Enum.any?(requests(log), &(&1["method"] == method)) do
      :ok
    else
      Process.sleep(10)
      wait_for(log, method, attempts - 1)
    end
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
    assert {:error, _, result} = Alto.run(%{"task" => "hang"}, opts(context, tool_timeout: 500))
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
