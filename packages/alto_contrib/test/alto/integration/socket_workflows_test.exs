defmodule Alto.Contrib.Integration.SocketWorkflowsTest do
  use ExUnit.Case, async: true
  alias Alto.Contrib.FrontEnd.Registry
  alias Alto.Contrib.Listeners.UnixSocket
  alias Alto.Contrib.Socket.Client
  alias Alto.{OperationLog, Queue}

  defmodule Tool do
    use Alto.Tool, name: :echo, execution_mode: :parallel, approval: :required
    def schema(_), do: Alto.TestSupport.EchoTool.schema([])

    def run(_, _, opts) do
      send(opts[:owner], :executed)
      {:ok, false}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-wire-flow-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    queue = start_supervised!({Queue, id: "queue", dir: Path.join(dir, "queue"), name: nil})

    ledger =
      start_supervised!({OperationLog, id: "ledger", dir: Path.join(dir, "ledger"), name: nil})

    owner = self()

    resolver = fn
      "guarded" ->
        {:ok,
         [
           provider: Alto.TestSupport.ToolThenAnswerProvider,
           tools: [{Tool, owner: owner}],
           approval: &Alto.Contrib.Approval.socket/2
         ]}

      _ ->
        {:error, :unknown_config}
    end

    registry =
      start_supervised!(
        {Registry,
         name: nil,
         cwd: dir,
         queue: queue,
         ledger: ledger,
         sessions: [session_dir: dir],
         config_resolver: resolver}
      )

    path = Path.join(dir, "wire.sock")
    start_supervised!({UnixSocket, name: nil, registry: registry, path: path})
    assert {:ok, client} = Client.connect(path)
    on_exit(fn -> Client.close(client) end)
    assert {:ok, %{"type" => "hello", "v" => 1}} = Client.next(client)
    %{queue: queue, ledger: ledger, registry: registry, client: client, dir: dir, path: path}
  end

  test "approval, denial, cancellation and saved replay cross the real socket", c do
    request(c, "attach")

    for decision <- ["approve", "deny"] do
      run = request(c, "start_run", %{"config" => "guarded", "task" => "work"})
      approval = notification(c.client, "approval_request")
      assert approval["run_id"] == run["run_id"]

      request(c, "approval_response", %{
        "request_id" => approval["request"]["id"],
        "decision" => if(decision == "approve", do: "approve", else: %{"deny" => "operator"})
      })

      result = notification(c.client, "result")
      assert result["run_id"] == run["run_id"]
      assert result["status"] == "ok"
      assert result["output"] == "finished"
      if decision == "approve", do: assert_received(:executed), else: refute_received(:executed)
      page = request(c, "session_events", %{"session_id" => run["session_id"], "limit" => 1})
      assert length(page["events"]) == 1
      assert page["next_cursor"] > 0

      messages =
        request(c, "session_transcript", %{"session_id" => run["session_id"]})["messages"]

      assert messages != []

      if decision == "approve",
        do: assert(Enum.any?(messages, &(&1["role"] == "tool" and &1["content"] == "false")))
    end

    run = request(c, "start_run", %{"config" => "guarded", "task" => "cancel"})
    _approval = notification(c.client, "approval_request")
    request(c, "cancel", %{"run_id" => run["run_id"], "reason" => "operator"})
    assert notification(c.client, "result")["status"] == "cancelled"
    refute_received :executed
  end

  test "operator pages redact payloads and preserve uncertainty while claims release and settle",
       c do
    for n <- 1..3,
        do:
          assert(
            {:ok, _} =
              Queue.request(c.queue, {:admit, "work-#{n}", %{private: "private-payload"}, []})
          )

    assert {:error, :duplicate} =
             Queue.request(c.queue, {:admit, "work-1", %{replacement: true}, []})

    page = request(c, "ops_list", %{"limit" => 2})
    assert length(page["items"]) == 2
    assert page["next_cursor"] == 2
    assert length(request(c, "ops_list", %{"cursor" => 2})["items"]) == 1
    refute inspect(page) =~ "private-payload"
    claimed = request(c, "queue_claim", %{"by" => "operator"})["records"] |> hd()
    request(c, "queue_release", %{"claim_id" => claimed["claim_id"]})
    next = request(c, "queue_claim")["records"] |> hd()
    assert next["id"] == claimed["id"]
    assert next["claim_id"] != claimed["claim_id"]
    assert request(c, "queue_ack", %{"claim_id" => claimed["claim_id"]})["code"] == "not_found"

    :ok =
      OperationLog.request(
        c.ledger,
        {:intent, next["operation_key"], "tool", next["key"],
         %{generation_id: next["generation_id"], payload: "private-recovery"}}
      )

    :ok = OperationLog.request(c.ledger, {:attempt, next["operation_key"], next["claim_id"]})

    packet = %{
      version: 2,
      status: "in_progress",
      action: "create",
      workspace: %{secret: "private-workspace"}
    }

    :ok =
      OperationLog.request(c.ledger, {:retain, "workspace", "workspace", nil, "attempt", packet})

    unknown = request(c, "ops_list", %{"filter" => "unknown"})
    assert Enum.all?(unknown["items"], &(&1["safe_to_retry"] == false))
    assert Enum.any?(unknown["items"], &(&1["key"] == "workspace"))
    assert Enum.any?(unknown["items"], &(&1["key"] == next["key"]))
    refute inspect(unknown) =~ "private-recovery"
    refute inspect(unknown) =~ "private-workspace"
    request(c, "queue_ack", %{"claim_id" => next["claim_id"]})
    assert %{pending: 2, claimed: 0} = Queue.request(c.queue, :count)
    assert request(c, "queue_ack", %{"claim_id" => next["claim_id"]})["code"] == "not_found"
  end

  test "operator inspection separates completed and new generations of the same display key", c do
    assert {:ok, _} = Queue.request(c.queue, {:put, "same-display", %{}, []})
    old = request(c, "queue_claim")["records"] |> hd()
    operation = old["operation_key"]
    claim = old["claim_id"]

    assert :ok =
             OperationLog.request(
               c.ledger,
               {:intent, operation, "tool", "same-display",
                %{key: "same-display", generation_id: old["generation_id"]}}
             )

    assert :ok = OperationLog.request(c.ledger, {:attempt, operation, claim})
    assert :ok = OperationLog.request(c.ledger, {:outcome, operation, claim, :completed, %{}})
    request(c, "queue_ack", %{"claim_id" => claim})
    assert {:ok, _} = Queue.request(c.queue, {:put, "same-display", %{}, []})

    assert [fresh, completed] = request(c, "ops_list")["items"]
    assert fresh["key"] == completed["key"]
    assert fresh["status"] == "accepted"
    assert completed["status"] == "completed"
    assert fresh["live"]["operation_key"] != operation
    assert completed["ledger"]["operation_key"] == operation
  end

  for store <- [Queue, OperationLog] do
    test "operator inspection reports an unavailable #{inspect(store)} instead of empty work",
         c do
      stop_supervised!(unquote(store))

      assert %{"type" => "error", "code" => "internal", "detail" => detail} =
               request(c, "ops_list")

      assert detail["$tuple"] |> hd() == "ops_unavailable"
      assert request(c, "runs")["runs"] == []
    end
  end

  test "invalid command envelopes fail without dispatch and leave the connection usable", c do
    assert {:ok, socket} =
             :gen_tcp.connect({:local, c.path}, 0, [:binary, active: false, packet: :line])

    on_exit(fn -> :gen_tcp.close(socket) end)
    assert {:ok, _hello} = :gen_tcp.recv(socket, 0, 2_000)

    for command <- [
          %{"type" => "start_run", "task" => "missing config"},
          %{
            "type" => "start_run",
            "config" => "guarded",
            "task" => "forged",
            "overrides" => %{"approval" => "approve"}
          },
          %{"type" => "cancel"},
          %{"type" => "queue_claim", "count" => 0},
          %{"type" => "queue_ack", "claim_id" => 5},
          %{"type" => "approval_response", "request_id" => "missing", "decision" => "maybe"},
          %{"type" => "ops_list", "limit" => 0},
          %{"type" => "ops_list", "cursor" => -1},
          %{"type" => "ops_list", "filter" => "invented"},
          %{"type" => "command", "name" => "anything", "payload" => []},
          %{"type" => "session_transcript", "session_id" => "../escape"}
        ] do
      envelope = Map.merge(%{"v" => 1, "id" => "rejected"}, command)
      :ok = :gen_tcp.send(socket, [JSON.encode!(envelope), "\n"])
      assert {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
      assert %{"type" => "error"} = JSON.decode!(line)
      refute_received :executed
    end

    assert request(c, "runs")["runs"] == []
    assert request(c, "ops_list")["items"] == []
    assert request(c, "start_run", %{"config" => "absent", "task" => "work"})["type"] == "error"
  end

  defp request(c, type, fields \\ %{}) do
    case Client.request(c.client, Map.put(fields, "type", type)) do
      {:ok, response} ->
        response

      {:error, {:server, code, detail}} ->
        %{"type" => "error", "code" => code, "detail" => detail}

      other ->
        flunk("unexpected #{type} reply: #{inspect(other)}")
    end
  end

  defp notification(client, type, remaining \\ 100)
  defp notification(_, type, 0), do: flunk("missing #{type} notification")

  defp notification(client, type, remaining) do
    assert {:ok, message} = Client.next(client, 2_000)
    if message["type"] == type, do: message, else: notification(client, type, remaining - 1)
  end
end
