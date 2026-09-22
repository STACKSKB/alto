defmodule Alto.Subagents.ContinuationTest do
  use ExUnit.Case, async: true

  alias Alto.OperationLog
  alias Alto.Subagents.Continuation

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-journal-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, id: "journal-" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  defp start_ledger!(dir, id, opts \\ []) do
    child_id = {:journal_ledger, id}

    pid =
      start_supervised!({OperationLog, Keyword.merge([id: id, dir: dir, name: nil], opts)},
        id: child_id
      )

    %{ledger: pid, child_id: child_id}
  end

  defp open!(ledger, key, ids, metadata \\ %{}) do
    {:ok, batch} = Continuation.open(ledger, key, ids, metadata)
    batch
  end

  test "opening persists one initialized checkpoint and one attempt", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-atomic-open", ["a", "b"])

    assert {:ok, %{revision: 1, state: :active, packet: packet}} = Continuation.read(batch)
    assert packet["phase"] == "children"
    assert packet["join"] == nil
    assert Enum.sort(Map.keys(packet["children"])) == ["a", "b"]
    assert OperationLog.attempts(ledger, "batch-atomic-open") == 1

    assert {:ok, reopened} = Continuation.open(ledger, "batch-atomic-open", ["a", "b"])
    assert Continuation.identity(reopened) == Continuation.identity(batch)
    assert {:ok, %{revision: 1}} = Continuation.read(reopened)
    assert OperationLog.attempts(ledger, "batch-atomic-open") == 1
  end

  test "concurrent dispatch grants a child exactly once", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-concurrent", ["child-a"])
    tasks = for _ <- 1..2, do: Task.async(fn -> Continuation.dispatch(batch, "child-a") end)
    results = Enum.map(tasks, &Task.await(&1, 1_000))
    assert Enum.count(results, &match?({:ok, %Continuation.Ticket{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :child_already_admitted})) == 1
  end

  test "completion joins in input order and survives restart with its generation", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger, child_id: child_id} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-order", ["z-first", "a-second"], %{origin: {:native, 1}})
    identity = Continuation.identity(batch)
    {:ok, first} = Continuation.dispatch(batch, "z-first")
    {:ok, second} = Continuation.dispatch(batch, "a-second")
    assert {:ok, _} = Continuation.complete(second, nil)
    assert {:ok, _} = Continuation.complete(first, %{value: 1})
    assert {:ok, snapshot} = Continuation.read(batch)
    assert snapshot.packet["children"]["z-first"]["result"] == %{value: 1}
    stop_supervised!(child_id)

    %{ledger: restarted} = start_ledger!(dir, id)
    {:ok, restored} = Continuation.restore(restarted, identity)

    assert {:ok,
            %{
              results: [{"z-first", %{value: 1}}, {"a-second", nil}],
              metadata: %{origin: {:native, 1}}
            }} =
             Continuation.join(restored)
  end

  test "lookup reads an existing batch without initializing it", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-lookup", ["child-a"])
    {:ok, before} = Continuation.read(batch)

    assert {:ok, looked_up, snapshot} = Continuation.lookup(ledger, "batch-lookup")
    assert looked_up.generation == batch.generation
    assert snapshot == before
    assert Continuation.read(batch) == {:ok, before}

    assert {:error, :not_found} = Continuation.lookup(ledger, "missing-batch")

    assert {:error, :invalid_retained_options} =
             Continuation.lookup(ledger, "batch-lookup", typo: true)

    assert :ok = OperationLog.record_intent(ledger, "wrong-kind", "other", nil, %{})
    assert {:error, :invalid_batch} = Continuation.lookup(ledger, "wrong-kind")
  end

  test "a dispatched child remains pending after restart and cannot be redispatched", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger, child_id: child_id} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-pending", ["child-a"])
    identity = Continuation.identity(batch)
    {:ok, _ticket} = Continuation.dispatch(batch, "child-a")
    stop_supervised!(child_id)

    %{ledger: restarted} = start_ledger!(dir, id)
    {:ok, restored} = Continuation.restore(restarted, identity)
    assert {:error, :child_already_admitted} = Continuation.dispatch(restored, "child-a")

    assert {:ok, %{packet: %{"children" => %{"child-a" => %{"state" => "dispatched"}}}}} =
             Continuation.read(restored)
  end

  test "forged and conflicting results are rejected while an exact retry is idempotent", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-conflict", ["child-a"])
    {:ok, ticket} = Continuation.dispatch(batch, "child-a")

    forged = %Continuation.Ticket{
      batch: batch,
      id: "child-a",
      attempt: "00000000000000000000000000000000"
    }

    assert {:error, :child_result_conflict} = Continuation.complete(forged, :forged)
    assert {:ok, _} = Continuation.complete(ticket, 1)
    assert {:ok, _} = Continuation.complete(ticket, 1)
    assert {:error, :child_result_conflict} = Continuation.complete(ticket, 1.0)
    assert {:error, :child_result_conflict} = Continuation.complete(ticket, :different)
  end

  test "skip only admits planned children", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-skip", ["planned", "dispatched"])
    {:ok, ticket} = Continuation.dispatch(batch, "dispatched")
    assert {:ok, _} = Continuation.skip(batch, "planned", :cancelled)
    assert {:error, :child_already_admitted} = Continuation.skip(batch, "planned", :again)
    assert {:error, :child_already_admitted} = Continuation.skip(batch, "dispatched", :cancelled)
    assert {:ok, _} = Continuation.complete(ticket, :done)
  end

  test "stale acknowledgement is fenced and retirement allows eviction and key reuse", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger} = start_ledger!(dir, id, max_ops: 1)
    batch = open!(ledger, "batch-retire", ["child-a"])
    {:ok, ticket} = Continuation.dispatch(batch, "child-a")
    assert {:ok, _} = Continuation.complete(ticket, :done)
    {:ok, joined} = Continuation.join(batch)

    assert {:error, :invalid_or_stale_join} =
             Continuation.acknowledge(batch, joined.revision - 1, %{"saved" => true})

    assert {:error, :ledger_full} = Continuation.open(ledger, "overflow-before-ack", ["child-a"])
    {:ok, acknowledged} = Continuation.acknowledge(batch, joined.revision, %{"saved" => true})
    assert {:error, :ledger_full} = Continuation.open(ledger, "overflow-after-ack", ["child-a"])
    assert :ok = Continuation.retire(batch, acknowledged.revision)
    assert {:ok, retired} = Continuation.read(batch)
    assert retired.state == :retired

    evict_batch = open!(ledger, "evict-retired", ["child-a"])
    {:ok, evict_ticket} = Continuation.dispatch(evict_batch, "child-a")
    assert {:ok, _} = Continuation.complete(evict_ticket, :done)
    {:ok, evict_joined} = Continuation.join(evict_batch)

    {:ok, evict_acknowledged} =
      Continuation.acknowledge(evict_batch, evict_joined.revision, %{"saved" => true})

    assert :ok = Continuation.retire(evict_batch, evict_acknowledged.revision)
    reused = open!(ledger, "batch-retire", ["child-a"])
    assert reused.generation != batch.generation
    assert {:error, :batch_generation_mismatch} = Continuation.read(batch)
  end

  test "unavailable and full ledgers fail closed", %{dir: dir, id: id} do
    %{ledger: ledger, child_id: child_id} = start_ledger!(dir, id)
    stop_supervised!(child_id)

    assert {:error, {:subagent_journal_unavailable, _}} =
             Continuation.open(ledger, "unavailable", ["child-a"])

    %{ledger: full} = start_ledger!(dir, id <> "-full", max_ops: 1)
    _ = open!(full, "held", ["child-a"])
    assert {:error, :ledger_full} = Continuation.open(full, "overflow", ["child-a"])
  end

  test "failed retirement append leaves the acknowledged batch intact across restart", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger, child_id: child_id} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-atomic-retire", ["child-a"])
    {:ok, ticket} = Continuation.dispatch(batch, "child-a")
    assert {:ok, _} = Continuation.complete(ticket, :done)
    {:ok, joined} = Continuation.join(batch)
    {:ok, acknowledged} = Continuation.acknowledge(batch, joined.revision, %{"saved" => true})

    attempts = OperationLog.attempts(ledger, batch.key)
    size = File.stat!(Path.join(dir, id <> ".jsonl")).size
    :sys.replace_state(ledger, fn state -> %{state | max_log_bytes: size + 1} end)

    assert {:error, {:ledger_log_too_large, _, _}} =
             Continuation.retire(batch, acknowledged.revision)

    assert Continuation.read(batch) == {:ok, acknowledged}
    assert OperationLog.attempts(ledger, batch.key) == attempts

    stop_supervised!(child_id)
    %{ledger: restarted} = start_ledger!(dir, id)
    {:ok, restored} = Continuation.restore(restarted, Continuation.identity(batch))
    assert Continuation.read(restored) == {:ok, acknowledged}
    assert :ok = Continuation.retire(restored, acknowledged.revision)
    assert {:ok, %{state: :retired, revision: revision}} = Continuation.read(restored)
    assert revision == acknowledged.revision + 1
    assert OperationLog.attempts(restarted, batch.key) == attempts + 1
  end

  test "concurrent retirement calls converge on one terminal record", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-retire-race", ["child-a"])
    {:ok, ticket} = Continuation.dispatch(batch, "child-a")
    assert {:ok, _} = Continuation.complete(ticket, :done)
    {:ok, joined} = Continuation.join(batch)
    {:ok, acknowledged} = Continuation.acknowledge(batch, joined.revision, %{"saved" => true})

    tasks =
      for _ <- 1..2,
          do: Task.async(fn -> Continuation.retire(batch, acknowledged.revision) end)

    results = Enum.map(tasks, &Task.await(&1, 1_000))
    assert :ok in results

    assert Enum.all?(
             results,
             &(&1 in [:ok, {:error, :invalid_or_stale_join}, {:error, :stale_revision}])
           )

    assert {:ok, %{state: :retired, revision: revision}} = Continuation.read(batch)
    assert revision == acknowledged.revision + 1
    assert OperationLog.attempts(ledger, batch.key) == 2
  end

  test "nonportable and oversized results never replace the dispatched state", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "bounds", ["worker"])
    {:ok, ticket} = Continuation.dispatch(batch, "worker")
    before = Continuation.read(batch)
    assert {:error, :checkpoint_not_portable_or_too_large} = Continuation.complete(ticket, self())

    assert {:error, :checkpoint_not_portable_or_too_large} =
             Continuation.complete(ticket, [1 | :improper])

    assert {:error, {:child_result_too_large, 64_000}} =
             Continuation.complete(ticket, String.duplicate("x", 65_000))

    assert Continuation.read(batch) == before
    result = String.duplicate("x", 50_000)
    assert {:ok, _} = Continuation.complete(ticket, result)
    assert {:ok, %{results: [{"worker", ^result}]}} = Continuation.join(batch)
  end

  test "parent batches reject receipts and delayed child writes without changing state", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger} = start_ledger!(dir, id)

    assert {:ok, cell} =
             Continuation.open_parent(
               ledger,
               "parent-batch",
               ["child-a"],
               %{},
               %{"frame" => "pending"}
             )

    assert {:ok, ticket} = Continuation.dispatch(cell, "child-a")
    assert {:ok, _} = Continuation.complete(ticket, :done)
    assert {:ok, joined} = Continuation.join(cell)

    assert {:error, :invalid_or_stale_join} =
             Continuation.acknowledge(cell, joined.revision, %{"saved" => true})

    assert {:ok, unchanged} = Continuation.read(cell)
    assert unchanged.revision == joined.revision
    assert unchanged.packet == joined.packet

    assert {:ok, ready} =
             Continuation.ready(cell, joined.revision, %{"frame" => "ready"})

    assert {:error, :continuation_children_closed} = Continuation.complete(ticket, :done)
    assert Continuation.read(cell) == {:ok, ready}
  end

  test "concurrent opens converge and completing 64 children does not consume ledger attempts", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger} =
      start_ledger!(dir, id, max_recovery_bytes: 128_000, max_record_bytes: 256_000)

    ids = Enum.map(1..64, &Integer.to_string/1)

    batches =
      1..4
      |> Enum.map(fn _ -> Task.async(fn -> Continuation.open(ledger, "many", ids) end) end)
      |> Enum.map(&Task.await(&1, 2_000))

    assert Enum.all?(batches, &match?({:ok, %Continuation{}}, &1))
    [{:ok, batch} | _] = batches
    assert Enum.all?(batches, fn {:ok, opened} -> opened.generation == batch.generation end)

    results =
      ids
      |> Enum.map(fn child ->
        Task.async(fn ->
          with {:ok, ticket} <- Continuation.dispatch(batch, child),
               do: Continuation.complete(ticket, child)
        end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert {:ok, joined} = Continuation.join(batch)
    assert joined.results == Enum.map(ids, &{&1, &1})
    assert OperationLog.attempts(ledger, "many") == 1
  end

  test "approval decisions and grants are fenced independently from sibling changes", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "approval-batch", ["one", "two"])
    {:ok, one} = Continuation.dispatch(batch, "one")
    {:ok, two} = Continuation.dispatch(batch, "two")
    checkpoint = %{"kind" => "child", "request" => %{"tool" => "write"}, "state" => "opaque"}
    assert {:ok, _} = Continuation.suspend(one, checkpoint)
    assert {:ok, _} = Continuation.suspend(two, checkpoint)
    assert {:ok, [%{identity: first}, %{identity: second}]} = Continuation.suspended(batch)
    {:ok, viewed} = Continuation.read(batch)
    assert {:ok, inspected} = Continuation.inspect_approval(batch, viewed.revision, "one")
    assert inspected.id == "one"
    assert inspected.state == :suspended
    assert inspected.checkpoint == checkpoint
    assert inspected.revision == viewed.revision

    assert {:error, :stale_child_approval} =
             Continuation.inspect_approval(batch, viewed.revision - 1, "one")

    assert {:ok, _} = Continuation.decide(batch, viewed.revision, first, :approve)

    assert {:error, :stale_child_decision} =
             Continuation.decide(batch, viewed.revision, second, :deny)

    {:ok, viewed} = Continuation.read(batch)
    assert {:ok, _} = Continuation.decide(batch, viewed.revision, second, :deny)

    tasks =
      for _ <- 1..2, do: Task.async(fn -> Continuation.claim_child(batch, first, :approve) end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :child_resume_not_granted})) == 1
    assert {:error, :child_result_conflict} = Continuation.complete(one, %{value: "stale worker"})

    assert {:ok, _} =
             Continuation.complete(
               Enum.find_value(results, fn
                 {:ok, ticket} -> ticket
                 _ -> nil
               end),
               %{value: "approved"}
             )

    assert {:ok, second_ticket} = Continuation.claim_child(batch, second, :deny)
    assert {:ok, _} = Continuation.complete(second_ticket, %{value: "denied"})

    assert {:ok, %{results: [{"one", %{value: "approved"}}, {"two", %{value: "denied"}}]}} =
             Continuation.join(batch)
  end
end
