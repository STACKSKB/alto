defmodule Alto.OpsTest do
  @moduledoc """
  conformance: bounded read-only operator inspection.

  Pagination and payload limits hold; stale claims read accurately;
  parked work survives restart; mutating recovery still requires the
  existing queue/ledger identities; unknown work is never safely
  retryable. The surface grants no new authority by construction
  (no mutating function exists here).
  """

  use ExUnit.Case, async: true

  alias Alto.OperationLog
  alias Alto.Ops
  alias Alto.Queue

  setup context do
    dir = Path.join(System.tmp_dir!(), "alto-ops-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    tag = System.unique_integer([:positive])
    qname = :"ops_q_#{tag}"
    lname = :"ops_l_#{tag}"

    {:ok, _} =
      Queue.start_link(
        id: "q#{tag}",
        dir: Path.join(dir, "q"),
        name: qname,
        lease_ms: Map.get(context, :lease_ms, 5_000)
      )

    {:ok, _} = OperationLog.start_link(id: "l#{tag}", dir: Path.join(dir, "l"), name: lname)

    %{dir: dir, queue: qname, ledger: lname, tag: tag}
  end

  test "accepted and claimed work show source and correlation", %{queue: q, ledger: l} do
    {:ok, _} = Queue.admit(q, "/hooks/events:del-1", %{"body" => "x"})
    {:ok, _} = Queue.put(q, "job-9", %{"total" => 1})
    {:ok, [claimed]} = Queue.claim(q, 1, "station-1")

    {:ok, %{items: items}} = Ops.list(q, l, limit: 20)
    by_key = Map.new(items, &{&1.key, &1})

    assert %{status: :claimed, source: "/hooks/events", claim_id: claim_id} =
             by_key["/hooks/events:del-1"]

    assert claim_id == claimed.claim_id
    assert %{status: :accepted, source: "business", operation: "job-9"} = by_key["job-9"]

    # Correlation is inbox key + claim identity, never an invented run.
    assert by_key["/hooks/events:del-1"].record_id == claimed.id
    assert by_key["/hooks/events:del-1"].safe_to_retry == false
  end

  test "inspection accepts a registered ledger reference", %{queue: queue, ledger: ledger} do
    name = {:alto_ops_ledger, System.unique_integer([:positive])}
    :yes = :global.register_name(name, Process.whereis(ledger))
    on_exit(fn -> :global.unregister_name(name) end)

    {:ok, _} = Queue.put(queue, "job", %{})

    assert {:ok, %{items: [%{key: "job", status: :accepted}]}} =
             Ops.list(queue, {:global, name})
  end

  @tag lease_ms: 50
  test "stale claims are visible accurately without mutating", %{queue: q, ledger: l} do
    {:ok, _} = Queue.admit(q, "src:stale", %{})
    {:ok, [claimed]} = Queue.claim(q, 1, "slow")
    Process.sleep(120)

    assert {:ok, item} = Ops.get(q, l, "src:stale")
    assert item.status == :claimed
    assert item.stale == true
    assert item.claim_id == claimed.claim_id
    assert item.reason =~ "stale"
  end

  test "inspection reaches live work beyond the oldest bounded page", %{queue: q, ledger: l} do
    for n <- 1..105 do
      {:ok, _} = Queue.put(q, "job-#{n}", %{n: n})
    end

    assert {:ok, item} = Ops.get(q, l, "job-105")
    assert item.status == :accepted
    assert item.key == "job-105"

    assert {:ok, %{items: page, next_cursor: nil}} = Ops.list(q, l, limit: 20, cursor: 100)

    assert Enum.map(page, & &1.key) == [
             "job-101",
             "job-102",
             "job-103",
             "job-104",
             "job-105"
           ]
  end

  test "parked work lists with bounded reasons and survives restart", %{
    dir: dir,
    queue: q,
    ledger: l,
    tag: tag
  } do
    {:ok, _} = Queue.admit(q, "src:park-me", %{"body" => "x"})
    {:ok, [claimed]} = Queue.claim(q, 1, "w")
    :ok = OperationLog.record_intent(l, "src:park-me", "print", "src:park-me")
    :ok = OperationLog.record_attempt(l, "src:park-me", claimed.claim_id)

    :ok =
      OperationLog.record_outcome(l, "src:park-me", claimed.claim_id, :requires_operator, %{
        park_reason: :handler_crashed,
        detail: String.duplicate("x", 5_000)
      })

    :ok = Queue.ack(q, claimed.claim_id)

    {:ok, %{items: [parked]}} = Ops.list(q, l, filter: :parked)
    assert parked.key == "src:park-me"
    assert parked.status == :parked
    assert parked.safe_to_retry == false
    assert byte_size(parked.reason) <= 501
    assert parked.recovery =~ "record_outcome"

    # Restart both stores over the same logs: parked work is still found.
    GenServer.stop(Process.whereis(q))
    GenServer.stop(Process.whereis(l))
    Process.sleep(10)

    q2 = :"ops_q2_#{tag}"
    l2 = :"ops_l2_#{tag}"
    {:ok, _} = Queue.start_link(id: "q#{tag}", dir: Path.join(dir, "q"), name: q2)
    {:ok, _} = OperationLog.start_link(id: "l#{tag}", dir: Path.join(dir, "l"), name: l2)

    assert {:ok, %{items: [found]}} = Ops.list(q2, l2, filter: :parked)
    assert found.key == "src:park-me"
  end

  test "unknown work is never shown as safely retryable", %{queue: q, ledger: l} do
    {:ok, _} = Queue.admit(q, "src:mystery", %{})
    {:ok, [claimed]} = Queue.claim(q, 1, "w")
    :ok = OperationLog.record_intent(l, "src:mystery", "print", "src:mystery")
    :ok = OperationLog.record_attempt(l, "src:mystery", claimed.claim_id)

    {:ok, %{items: [item]}} = Ops.list(q, l, filter: :unknown)
    assert item.key == "src:mystery"
    assert item.safe_to_retry == false
    assert item.recovery =~ "never blind retry"
    refute item.recovery =~ "safely retry"
  end

  test "recovery identities are exposed without exposing the recovery payload", %{
    queue: q,
    ledger: l
  } do
    {:ok, _} = Queue.admit(q, "src:identity", %{})
    {:ok, [claimed]} = Queue.claim(q, 1, "w")

    :ok =
      OperationLog.record_intent(l, "src:identity", "print", "src:identity", %{
        generation_id: "recovery-generation",
        payload: String.duplicate("x", 5_000)
      })

    :ok = OperationLog.record_attempt(l, "src:identity", claimed.claim_id)

    assert {:ok, %{items: [item]}} = Ops.list(q, l, filter: :unknown)
    assert item.operation_revision == 2
    assert item.attempt_id == claimed.claim_id
    assert item.generation_id == "recovery-generation"
    assert item.recovery_available == true
    refute Map.has_key?(item, :recovery_envelope)
  end

  test "ledger projections preserve display keys beside semantic operation keys", %{
    queue: q,
    ledger: l
  } do
    {:ok, _} = Queue.put(q, "job-display", %{})
    {:ok, [claimed]} = Queue.claim(q, 1, "w")
    operation_key = "business-generation:" <> claimed.generation_id

    :ok =
      OperationLog.record_intent(
        l,
        operation_key,
        "print",
        "job-display",
        %{key: "job-display", generation_id: claimed.generation_id, payload: %{}}
      )

    :ok = OperationLog.record_attempt(l, operation_key, claimed.claim_id)

    assert {:ok, %{items: [item]}} = Ops.list(q, l, filter: :unknown)
    assert item.key == "job-display"
    assert item.operation == "job-display"
    assert item.operation_key == operation_key
    assert item.generation_id == claimed.generation_id
    assert item.attempt_id == claimed.claim_id
  end

  test "a completed business generation remains visible beside a new live generation", %{
    queue: q,
    ledger: l
  } do
    {:ok, _} = Queue.put(q, "same-display", %{})
    {:ok, [old_claim]} = Queue.claim(q, 1, "w")
    old_operation = "business-generation:" <> old_claim.generation_id

    :ok =
      OperationLog.record_intent(l, old_operation, "print", "same-display", %{
        key: "same-display",
        generation_id: old_claim.generation_id
      })

    :ok = OperationLog.record_attempt(l, old_operation, old_claim.claim_id)
    :ok = OperationLog.record_outcome(l, old_operation, old_claim.claim_id, :completed, %{})
    :ok = Queue.ack(q, old_claim.claim_id)
    {:ok, _} = Queue.put(q, "same-display", %{})

    assert {:ok, %{items: items}} = Ops.list(q, l)
    assert Enum.map(items, & &1.key) == ["same-display", "same-display"]
    assert Enum.map(items, & &1.status) == [:accepted, :completed]
    assert Enum.at(items, 0).operation_key != old_operation
    assert Enum.at(items, 1).operation_key == old_operation
  end

  test "restored work joins ledger state by its explicit operation key", %{queue: q, ledger: l} do
    operation_key = "src:restored-operation"
    {:ok, _} = Queue.restore(q, operation_key, "generation-1", %{})
    {:ok, [claimed]} = Queue.claim(q, 1, "w")
    :ok = OperationLog.record_intent(l, operation_key, "print", claimed.key)
    :ok = OperationLog.record_attempt(l, operation_key, claimed.claim_id)

    assert {:ok, %{items: [item]}} = Ops.list(q, l)
    assert item.status == :unknown
    assert item.key == claimed.key
    assert item.operation_key == operation_key
    assert item.claim_id == claimed.claim_id
  end

  test "completed work lists terminal outcomes; pagination and limits hold", %{
    queue: q,
    ledger: l
  } do
    for n <- 1..5 do
      key = "src:done-#{n}"
      {:ok, _} = Queue.admit(q, key, %{})
      {:ok, [claimed]} = Queue.claim(q, 1, "w")
      :ok = OperationLog.record_intent(l, key, "print", key)
      :ok = OperationLog.record_attempt(l, key, claimed.claim_id)
      :ok = OperationLog.record_outcome(l, key, claimed.claim_id, :completed, %{n: n})
      :ok = Queue.ack(q, claimed.claim_id)
    end

    {:ok, %{items: page1, next_cursor: cursor}} = Ops.list(q, l, filter: :completed, limit: 2)
    assert length(page1) == 2
    assert cursor == 2

    {:ok, %{items: page2, next_cursor: cursor2}} =
      Ops.list(q, l, filter: :completed, limit: 2, cursor: cursor)

    assert length(page2) == 2
    assert cursor2 == 4

    {:ok, %{items: page3, next_cursor: nil}} =
      Ops.list(q, l, filter: :completed, limit: 2, cursor: cursor2)

    assert length(page3) == 1
    assert Enum.all?(page1 ++ page2 ++ page3, &(&1.status == :completed))

    assert {:error, {:invalid_limit, 0}} = Ops.list(q, l, limit: 0)
    assert {:error, {:invalid_limit, 101}} = Ops.list(q, l, limit: 101)
    assert {:error, {:invalid_cursor, -1}} = Ops.list(q, l, cursor: -1)
    assert {:error, {:invalid_filter, :bogus}} = Ops.list(q, l, filter: :bogus)
    assert {:error, :not_found} = Ops.get(q, l, "src:missing")
  end

  test "store outages are reported instead of looking empty", %{queue: q, ledger: l} do
    GenServer.stop(Process.whereis(q))
    GenServer.stop(Process.whereis(l))
    assert {:error, _} = Ops.list(q, l)
    assert {:error, _} = Ops.get(q, l, "missing")
  end
end
