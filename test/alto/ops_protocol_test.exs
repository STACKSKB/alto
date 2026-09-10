defmodule Alto.OpsProtocolTest do
  @moduledoc """
  wire surface: `ops_list` rides the envelope codec and connection
  dispatch like every other command. Read-only and bounded: pages encode
  against the connection's `max_line_bytes`, missing stores answer
  `unsupported`, and bad pagination answers `invalid`. Recovery stays
  with the existing queue/ledger calls — no mutating operator command
  exists here.
  """

  use ExUnit.Case, async: true

  alias Alto.FrontEnd.Registry
  alias Alto.Listeners.Connection
  alias Alto.OperationLog
  alias Alto.Protocol
  alias Alto.Queue

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-ops-wire-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    tag = System.unique_integer([:positive])
    queue = :"ops_wire_q_#{tag}"
    ledger = :"ops_wire_l_#{tag}"
    {:ok, _} = Queue.start_link(id: "qw#{tag}", dir: Path.join(dir, "q"), name: queue)
    {:ok, _} = OperationLog.start_link(id: "lw#{tag}", dir: Path.join(dir, "l"), name: ledger)

    resolver = fn _name -> {:error, {:unknown_config, "nope"}} end
    registry = :"ops_wire_r_#{tag}"
    bare = :"ops_wire_bare_#{tag}"

    start_supervised!(%{
      id: registry,
      start:
        {Registry, :start_link,
         [[name: registry, config_resolver: resolver, queue: queue, ledger: ledger]]}
    })

    start_supervised!(%{
      id: bare,
      start: {Registry, :start_link, [[name: bare, config_resolver: resolver]]}
    })

    %{queue: queue, ledger: ledger, registry: registry, bare: bare}
  end

  defp run(line, registry, max_line_bytes \\ 1_048_576) do
    Connection.run_command(
      line,
      registry,
      fn out -> send(self(), {:line, out}) end,
      max_line_bytes
    )

    assert_receive {:line, out}
    JSON.decode!(IO.iodata_to_binary(out))
  end

  test "decode defaults and rejects bad pagination" do
    assert {:ok, {:ops_list, "c-1", 20, 0, nil}} =
             Protocol.decode_command(
               JSON.encode!(%{"v" => 1, "type" => "ops_list", "id" => "c-1"})
             )

    assert {:ok, {:ops_list, "c-2", 5, 10, "parked"}} =
             Protocol.decode_command(
               JSON.encode!(%{
                 "v" => 1,
                 "type" => "ops_list",
                 "id" => "c-2",
                 "limit" => 5,
                 "cursor" => 10,
                 "filter" => "parked"
               })
             )

    assert {:error, :invalid} =
             Protocol.decode_command(
               JSON.encode!(%{"v" => 1, "type" => "ops_list", "id" => "c-3", "limit" => 0})
             )

    assert {:error, :invalid} =
             Protocol.decode_command(
               JSON.encode!(%{"v" => 1, "type" => "ops_list", "id" => "c-4", "filter" => "bogus"})
             )
  end

  test "ops_list round-trips accepted work with correlation", %{
    queue: queue,
    registry: registry
  } do
    {:ok, _} = Queue.admit(queue, "/hooks/events:del-1", %{"body" => "x"})

    reply =
      run(
        JSON.encode!(%{"v" => 1, "type" => "ops_list", "id" => "c-1", "filter" => "accepted"}),
        registry
      )

    assert reply["type"] == "ok"

    assert [
             %{
               "key" => "/hooks/events:del-1",
               "status" => "accepted",
               "source" => "/hooks/events"
             }
           ] =
             reply["items"]

    assert reply["next_cursor"] == nil
  end

  test "pagination cursors page through completed work", %{
    queue: queue,
    ledger: ledger,
    registry: registry
  } do
    for n <- 1..3 do
      key = "src:done-#{n}"
      {:ok, _} = Queue.admit(queue, key, %{})
      {:ok, [claimed]} = Queue.claim(queue, 1, "w")
      :ok = OperationLog.record_intent(ledger, key, "print", key)
      :ok = OperationLog.record_attempt(ledger, key, claimed.claim_id)
      :ok = OperationLog.record_outcome(ledger, key, claimed.claim_id, :completed, %{})
      :ok = Queue.ack(queue, claimed.claim_id)
    end

    page1 =
      run(
        JSON.encode!(%{
          "v" => 1,
          "type" => "ops_list",
          "id" => "c-1",
          "filter" => "completed",
          "limit" => 2
        }),
        registry
      )

    assert length(page1["items"]) == 2
    assert page1["next_cursor"] == 2

    page2 =
      run(
        JSON.encode!(%{
          "v" => 1,
          "type" => "ops_list",
          "id" => "c-2",
          "filter" => "completed",
          "limit" => 2,
          "cursor" => 2
        }),
        registry
      )

    assert length(page2["items"]) == 1
    assert page2["next_cursor"] == nil
  end

  test "unknown work on the wire is never safely retryable", %{
    queue: queue,
    ledger: ledger,
    registry: registry
  } do
    {:ok, _} = Queue.admit(queue, "src:mystery", %{})
    {:ok, [claimed]} = Queue.claim(queue, 1, "w")
    :ok = OperationLog.record_intent(ledger, "src:mystery", "print", "src:mystery")
    :ok = OperationLog.record_attempt(ledger, "src:mystery", claimed.claim_id)

    reply =
      run(
        JSON.encode!(%{"v" => 1, "type" => "ops_list", "id" => "c-1", "filter" => "unknown"}),
        registry
      )

    assert [%{"key" => "src:mystery", "status" => "unknown", "safe_to_retry" => false}] =
             reply["items"]
  end

  test "missing stores answer unsupported; bad pagination answers invalid", %{
    bare: bare,
    registry: registry
  } do
    missing =
      run(JSON.encode!(%{"v" => 1, "type" => "ops_list", "id" => "c-9"}), bare)

    assert missing["code"] == "unsupported"

    bad =
      run(JSON.encode!(%{"v" => 1, "type" => "ops_list", "id" => "c-10", "limit" => 0}), registry)

    assert bad["code"] == "invalid"
  end

  test "an oversized page answers internal without mutating", %{queue: queue, registry: registry} do
    {:ok, _} = Queue.put(queue, "big", %{pad: String.duplicate("x", 5_000)})

    reply = run(JSON.encode!(%{"v" => 1, "type" => "ops_list", "id" => "c-1"}), registry, 200)

    assert reply["code"] == "internal"
    assert %{pending: 1, claimed: 0} = Queue.count(queue)
  end
end
