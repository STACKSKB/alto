defmodule Alto.Subagents.ContinuationFrameTest do
  use ExUnit.Case, async: true

  alias Alto.OperationLog
  alias Alto.Subagents.Continuation

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-frame-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    ledger =
      start_supervised!(
        {OperationLog,
         id: "frames-#{System.unique_integer([:positive])}",
         dir: dir,
         name: nil,
         max_recovery_bytes: 2_100_000,
         max_record_bytes: 2_500_000}
      )

    %{ledger: ledger}
  end

  test "frame-only continuation is retained, discovered, readied, and claimed once", %{
    ledger: ledger
  } do
    pending = %{"frame" => "pending"}
    assert {:error, :invalid_batch_plan} = Continuation.open(ledger, "parent", [])

    assert {:ok, cell} =
             Continuation.open(ledger, "parent", [], %{"run" => "one"}, parent: pending)

    assert {:ok, %{phase: :children, parent: ^pending, ids: [], revision: revision}} =
             Continuation.read(cell)

    assert {:ok, [%{identity: identity, snapshot: %{parent: ^pending}}]} =
             Continuation.list(ledger, %{"run" => "one"})

    assert identity == Continuation.identity(cell)
    ready_packet = %{"frame" => "ready"}

    assert {:ok, %{phase: :ready, revision: ready_revision}} =
             Continuation.ready(cell, revision, ready_packet)

    claims =
      1..4
      |> Enum.map(fn _ -> Task.async(fn -> Continuation.claim(cell, ready_revision) end) end)
      |> Enum.map(&Task.await(&1, 2_000))

    assert Enum.count(claims, &match?({:ok, %{phase: :claimed}}, &1)) == 1

    assert {:ok,
            %{phase: :claimed, revision: claimed_revision, packet: %{"packet" => ^ready_packet}}} =
             Continuation.read(cell)

    assert {:error, :invalid_continuation_phase} =
             Continuation.ready(cell, claimed_revision, %{"frame" => "again"})

    assert {:ok, %{phase: :claimed, revision: ^claimed_revision}} = Continuation.read(cell)
    assert :ok = Continuation.retire(cell, claimed_revision)
    assert {:ok, %{state: :retired}} = Continuation.read(cell)
  end

  test "pending parent packet is immutable recovery and bounded", %{ledger: ledger} do
    pending = %{"frame" => String.duplicate("p", 200_000)}
    assert {:ok, cell} = Continuation.open(ledger, "large", [], %{}, parent: pending)
    assert {:ok, entry} = OperationLog.recovery(ledger, "large")
    assert entry.recovery["parent"] == pending
    assert {:ok, %{parent: ^pending}} = Continuation.read(cell)

    assert {:error, :invalid_batch_key} =
             Continuation.open(ledger, "", [], %{}, parent: %{"frame" => "bad"})
  end

  test "foreign records are excluded from discovery", %{ledger: ledger} do
    assert :ok = OperationLog.record_intent(ledger, "foreign", "other", nil, %{})
    assert {:ok, []} = Continuation.list(ledger)

    assert :ok =
             OperationLog.record_intent(
               ledger,
               "corrupt-owned",
               "alto_subagent_continuation",
               nil,
               %{}
             )

    assert {:error, :invalid_batch} = Continuation.list(ledger)
  end

  test "retained children must exactly match the plan and contain valid state", %{ledger: ledger} do
    child = {:planned}
    attempt = String.duplicate("a", 32)
    token = String.duplicate("b", 32)
    saved = %{"checkpoint" => %{}, "workspace" => nil}

    invalid = [
      [child],
      %{},
      %{"other" => child},
      %{"worker" => 1},
      %{"worker" => {:planned, "worker"}},
      %{"worker" => {:dispatched, nil}},
      %{"worker" => {:completed, "invalid-attempt", :done}},
      %{"worker" => {:suspended, attempt, nil, saved}},
      %{"worker" => {:suspended, attempt, token, %{}}},
      %{"worker" => {:decided, attempt, token, saved, nil}},
      %{"worker" => {:resuming, attempt, token, saved, :approve, nil}}
    ]

    for {children, index} <- Enum.with_index(invalid) do
      key = "bad-children-#{index}"
      assert {:ok, cell} = Continuation.open(ledger, key, ["worker"])
      assert {:ok, snapshot} = Continuation.read(cell)

      assert {:ok, _} =
               OperationLog.update_checkpoint(
                 ledger,
                 key,
                 snapshot.revision,
                 %{snapshot.packet | "children" => children}
               )

      assert {:error, :invalid_batch} = Continuation.read(cell)
    end
  end

  test "metadata filters require present keys and discovery contains dead stores", %{
    ledger: ledger
  } do
    assert {:ok, _} = Continuation.open(ledger, "one", [], %{}, parent: %{"frame" => 1})
    assert {:ok, []} = Continuation.list(ledger, %{"missing" => nil})

    for key <- ["z", "a"] do
      assert {:ok, _} =
               Continuation.open(ledger, key, [], %{"group" => 1}, parent: %{"frame" => key})
    end

    assert {:ok, items} = Continuation.list(ledger, %{"group" => 1})
    assert Enum.map(items, & &1.identity["key"]) == ["a", "z"]

    for %{identity: identity, snapshot: snapshot} <- items do
      assert {:ok, cell} = Continuation.restore(ledger, identity)
      assert {:ok, ^snapshot} = Continuation.read(cell)
    end

    assert {:error, :run_timeout} =
             Continuation.list(ledger, %{}, deadline: System.monotonic_time(:millisecond) - 1)

    monitor = Process.monitor(ledger)
    Process.exit(ledger, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^ledger, _}
    assert {:error, {:subagent_journal_unavailable, _}} = Continuation.list(ledger)
  end
end
