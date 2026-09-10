defmodule Alto.External.MCP.ClientTest do
  use ExUnit.Case, async: false

  alias Alto.External.MCP.Client

  defmodule ToolCallingProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, _opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        {:ok, %{message: "external tool completed", tool_calls: []}}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [
             %{id: "mcp-1", name: "external_echo", arguments_json: ~s({"hello":"alto"})}
           ]
         }}
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-mcp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    server = Path.join(root, "server.exs")

    File.write!(server, """
    #!/usr/bin/env elixir
    Stream.repeatedly(fn -> IO.read(:stdio, :line) end)
    |> Enum.reduce_while(nil, fn
      :eof, _ -> {:halt, nil}
      {:error, _}, _ -> {:halt, nil}
      line, state ->
        message = JSON.decode!(line)
        id = message["id"]
        if message["method"] == "notifications/cancelled" do
          case System.get_env("CANCEL_FILE") do
            path when is_binary(path) -> File.write!(path, "cancelled")
            _ -> :ok
          end
        end
        if message["method"] == "tools/call" and System.get_env("SLOW") == "1", do: Process.sleep(250)
        response =
          case message["method"] do
            "initialize" ->
              %{"jsonrpc" => "2.0", "id" => id, "result" => %{"protocolVersion" => "2025-11-25", "capabilities" => %{}, "serverInfo" => %{"name" => "fake", "version" => "1"}}}
            "tools/list" ->
              IO.puts(JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => "server/ping", "params" => %{}}))
              %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => [%{"name" => "echo", "description" => "Echo", "inputSchema" => %{"type" => "object"}}]}}
            "tools/call" ->
              %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => [%{"type" => "text", "text" => JSON.encode!(message["params"]["arguments"])}]}}
            _ -> nil
          end
        if response, do: IO.puts(JSON.encode!(response))
        {:cont, state}
    end)
    """)

    File.chmod!(server, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, server: server}
  end

  test "retains one initialized stdio server and calls its advertised tools", %{
    root: root,
    server: server
  } do
    opts = [command: server, cwd: root, request_timeout: 5_000, startup_timeout: 5_000]

    assert {:ok, client} = Client.ensure_started(opts)
    on_exit(fn -> if Process.alive?(client), do: Client.stop(client) end)
    assert {:ok, same_client} = Client.ensure_started(opts)
    assert client == same_client

    assert {:ok, [%{"name" => "echo"}]} = Client.list_tools(client, 5_000)

    assert {:ok, %{"content" => [%{"text" => encoded}]}} =
             Client.call_tool(client, "echo", %{"hello" => "world"}, 5_000)

    assert JSON.decode!(encoded) == %{"hello" => "world"}
  end

  test "reports missing executables without hanging startup", %{root: root} do
    assert {:error, _reason} =
             Client.ensure_started(
               command: "alto-definitely-missing-mcp",
               cwd: root,
               startup_timeout: 5_000
             )
  end

  test "startup timeout stops a retained client", %{root: root} do
    assert {:error, _reason} =
             Client.ensure_started(
               command: System.find_executable("sh"),
               args: ["-c", "sleep 2"],
               cwd: root,
               startup_timeout: 50,
               request_timeout: 50
             )

    Process.sleep(25)

    assert {:error, _reason} =
             Client.ensure_started(
               command: System.find_executable("sh"),
               args: ["-c", "sleep 2"],
               cwd: root,
               startup_timeout: 50,
               request_timeout: 50
             )
  end

  test "a dispatched MCP timeout is uncertain and sends cancellation", %{
    root: root,
    server: server
  } do
    opts = [command: server, cwd: root, env: %{"SLOW" => "1"}, startup_timeout: 5_000]
    assert {:ok, client} = Client.ensure_started(opts)
    on_exit(fn -> if Process.alive?(client), do: Client.stop(client) end)

    assert {:unknown, {:mcp_request_timeout, _id}} =
             Client.call_tool(client, "echo", %{"hello" => "world"}, 50)
  end

  test "an MCP caller death removes pending work and sends cancellation", %{
    root: root,
    server: server
  } do
    cancellation = Path.join(root, "cancelled")

    opts = [
      command: server,
      cwd: root,
      env: %{"SLOW" => "1", "CANCEL_FILE" => cancellation},
      startup_timeout: 5_000
    ]

    assert {:ok, client} = Client.ensure_started(opts)
    on_exit(fn -> if Process.alive?(client), do: Client.stop(client) end)

    caller = spawn(fn -> Client.call_tool(client, "echo", %{"hello" => "world"}, 5_000) end)
    Process.sleep(25)
    Process.exit(caller, :kill)

    assert eventually(fn -> File.exists?(cancellation) end)
  end

  test "configured MCP tool instances expose dynamic Alto names and schemas", %{
    root: root,
    server: server
  } do
    tool =
      {Alto.Tools.MCP,
       name: :external_echo,
       remote_name: "echo",
       schema: %{description: "Echo", parameters: %{type: "object"}},
       server: [command: server, cwd: :workspace, request_timeout: 5_000, startup_timeout: 5_000],
       approval: :never}

    assert {:ok, result} =
             Alto.run("call it",
               cwd: root,
               provider: {ToolCallingProvider, []},
               tools: [tool],
               max_steps: 3
             )

    assert result.output == "external tool completed"
    assert Enum.any?(result.events, &(&1.type == :tool_completed))

    {:ok, client} =
      Client.ensure_started(
        command: server,
        cwd: root,
        request_timeout: 5_000,
        startup_timeout: 5_000
      )

    if Process.alive?(client), do: Client.stop(client)
  end

  test "an expired request waiting in the client mailbox never dispatches", %{
    root: root,
    server: server
  } do
    {:ok, client} = Client.ensure_started(command: server, cwd: root, startup_timeout: 5_000)
    :sys.suspend(client)
    task = Task.async(fn -> Client.call_tool(client, "echo", %{}, 20) end)
    Process.sleep(40)
    :sys.resume(client)
    assert {:error, :request_expired} = Task.await(task)
    assert :sys.get_state(client).next_id == 2
    Client.stop(client)
  end

  test "a killed client after possible dispatch reports unknown", %{root: root, server: server} do
    {:ok, client} =
      Client.ensure_started(
        command: server,
        cwd: root,
        startup_timeout: 5_000,
        env: %{"SLOW" => "1"}
      )

    task = Task.async(fn -> Client.call_tool(client, "echo", %{}, 5_000) end)
    assert eventually(fn -> map_size(:sys.get_state(client).pending) == 1 end)
    Process.exit(client, :kill)
    assert {:unknown, {:mcp_client_unavailable, _}} = Task.await(task)
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
