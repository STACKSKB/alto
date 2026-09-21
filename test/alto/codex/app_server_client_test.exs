defmodule Alto.Codex.AppServer.ClientTest do
  use ExUnit.Case, async: false

  alias Alto.Codex.AppServer.Client
  alias Alto.Codex.Backend

  setup do
    root = Path.join(System.tmp_dir!(), "alto-codex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    server = Path.join(root, "app_server.exs")

    File.write!(server, """
    #!/usr/bin/env elixir
    Stream.repeatedly(fn -> IO.read(:stdio, :line) end)
    |> Enum.reduce_while(%{thread: 0}, fn
      :eof, _state -> {:halt, nil}
      {:error, _}, _state -> {:halt, nil}
      line, state ->
        message = JSON.decode!(line)
        id = message["id"]
        method = message["method"]

        {response, state} =
          case method do
            "initialize" ->
              {%{"jsonrpc" => "2.0", "id" => id, "result" => %{"serverInfo" => %{"name" => "fake"}}}, state}
            "initialized" ->
              {nil, state}
            "account/read" ->
              IO.puts(JSON.encode!(%{"id" => id, "method" => "server/needsReply", "params" => %{}}))
              {%{"id" => id, "result" => %{"account" => %{"type" => "chatgpt", "email" => "pro@example.test", "planType" => "pro"}, "requiresOpenaiAuth" => true}}, state}
            "model/list" ->
              {%{"id" => id, "result" => %{"data" => [%{"id" => "gpt-test", "model" => "gpt-test", "displayName" => "GPT Test", "description" => "Test", "isDefault" => true, "defaultReasoningEffort" => "medium", "supportedReasoningEfforts" => []}], "nextCursor" => nil}}, state}
            "account/rateLimits/read" ->
              {%{"id" => id, "result" => %{"rateLimits" => %{"primary" => %{"usedPercent" => 12.5, "windowDurationMins" => 300, "resetsAt" => 1_900_000_000}}}}, state}
            "account/login/start" ->
              {%{"id" => id, "result" => %{"type" => "chatgpt", "loginId" => "login-1", "authUrl" => "https://chatgpt.test/oauth"}}, state}
            "thread/start" ->
              {%{"id" => id, "result" => %{"thread" => %{"id" => "thr-1"}}}, %{state | thread: 1}}
            "thread/resume" ->
              {%{"id" => id, "result" => %{"thread" => %{"id" => message["params"]["threadId"]}}}, state}
            "turn/start" ->
              IO.puts(JSON.encode!(%{"method" => "test/turnParams", "params" => message["params"]}))
              response = %{"id" => id, "result" => %{"turn" => %{"id" => "turn-1", "status" => "inProgress"}}}
              IO.puts(JSON.encode!(response))
              IO.puts(JSON.encode!(%{"method" => "item/agentMessage/delta", "params" => %{"threadId" => "thr-1", "turnId" => "turn-1", "itemId" => "msg-1", "delta" => "hello"}}))
              {nil, state}
            "thread/read" ->
              if message["params"]["threadId"] == "thr-tools" do
                items = [%{"type" => "commandExecution", "command" => "ls -la", "aggregatedOutput" => "file.txt", "status" => "failed", "exitCode" => 2},
                  %{"type" => "fileChange", "changes" => [%{"path" => "file.txt", "kind" => "added"}]},
                  %{"type" => "mcpToolCall", "server" => "test", "tool" => "lookup", "result" => %{"error" => %{"message" => "Not available", "code" => 503}}}]
                {%{"id" => id, "result" => %{"thread" => %{"turns" => [%{"items" => items}]}}}, state}
              else
              turns = [%{"id" => "turn-old", "status" => "completed", "items" => [%{"id" => "user", "type" => "userMessage", "content" => [%{"type" => "text", "text" => "old prompt"}]}, %{"id" => "agent", "type" => "agentMessage", "text" => "old answer"}]}]
              {%{"id" => id, "result" => %{"thread" => %{"id" => "thr-1", "turns" => turns}}}, state}
              end
            _ ->
              if id, do: {%{"id" => id, "result" => %{}}, state}, else: {nil, state}
          end

        if response, do: IO.puts(JSON.encode!(response))
        {:cont, state}
    end)
    """)

    File.chmod!(server, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, server: server}
  end

  test "retains an initialized App Server and streams notifications", %{
    root: root,
    server: server
  } do
    opts = [command: server, args: [], cwd: root, startup_timeout: 5_000, request_timeout: 5_000]

    assert {:ok, client} = Client.ensure_started(opts)
    assert {:ok, ^client} = Client.ensure_started(Enum.reverse(opts))
    assert {:ok, isolated} = Client.ensure_started(Keyword.put(opts, :instance, :isolated))
    refute isolated == client
    GenServer.stop(isolated)
    assert :ok = Client.subscribe(client)

    assert {:ok, %{"account" => %{"type" => "chatgpt", "planType" => "pro"}}} =
             Client.account(client)

    assert_receive {:codex_request, ^client, _request_id, "server/needsReply", %{}}

    assert {:ok, %{models: [%{id: "gpt-test"}], rate_limits: limits}} = Backend.refresh(client)
    assert get_in(limits, ["rateLimits", "primary", "usedPercent"]) == 12.5

    assert {:ok, %{thread_id: "thr-1", turn_id: "turn-1"}} =
             Backend.start_turn(client, nil, "hello",
               cwd: root,
               model: "gpt-test",
               effort: "high",
               approval: :ask
             )

    assert_receive {:codex_notification, ^client, "test/turnParams",
                    %{"effort" => "high", "summary" => "auto"}}

    assert_receive {:codex_notification, ^client, "item/agentMessage/delta",
                    %{"delta" => "hello"}}

    assert {:ok,
            [%{kind: :user, text: "old prompt"}, %{kind: :codex_assistant, text: "old answer"}]} =
             Backend.history(client, "thr-1")
  end

  test "infinite request timeout settles without cancelling a nil timer", %{
    root: root,
    server: server
  } do
    assert {:ok, client} = Client.ensure_started(command: server, args: [], cwd: root)
    assert {:ok, %{"data" => [_]}} = Client.request(client, "model/list", %{}, :infinity)
    assert Process.alive?(client)
  end

  test "restored Codex tool history uses readable result fields", %{root: root, server: server} do
    {:ok, client} =
      Client.ensure_started(command: server, args: [], cwd: root, request_timeout: 5_000)

    assert {:ok, [command, file, mcp]} = Backend.history(client, "thr-tools")
    assert command.text == "command · ls -la"
    assert command.detail =~ "Status: Failed"
    assert command.detail =~ "Exit Code: 2"
    assert file.detail =~ "Path: file.txt"
    assert mcp.detail =~ "Message: Not available"

    for entry <- [command, file, mcp] do
      refute entry.text =~ "%{"
      refute entry.detail =~ "%{"
      refute entry.detail =~ "=>"
    end

    assert command ==
             Backend.item_entry(%{
               "type" => "commandExecution",
               "command" => "ls -la",
               "aggregatedOutput" => "file.txt",
               "status" => "failed",
               "exitCode" => 2
             })
  end

  test "approval levels map to Codex policy and sandbox independently", _context do
    assert Backend.approval_policy(:ask) == "on-request"
    assert Backend.sandbox_policy(:ask)["type"] == "workspaceWrite"
    assert Backend.approval_policy(:read_only) == "never"
    assert Backend.sandbox_policy(:read_only)["type"] == "readOnly"
    assert Backend.approval_policy(:full_access) == "never"
    assert Backend.sandbox_policy(:full_access)["type"] == "dangerFullAccess"
  end

  test "reports a missing Codex executable without hanging", %{root: root} do
    assert {:error, {:codex_executable_not_found, _}} =
             Client.ensure_started(command: "alto-missing-codex", cwd: root, startup_timeout: 100)
  end
end
