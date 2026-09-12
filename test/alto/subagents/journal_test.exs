defmodule Alto.Subagents.JournalTest do
  use ExUnit.Case, async: true

  alias Alto.OperationLog
  alias Alto.Subagents.Journal

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
    {:ok, batch} = Journal.open(ledger, key, ids, metadata)
    batch
  end

  test "concurrent dispatch grants a child exactly once", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-concurrent", ["child-a"])
    tasks = for _ <- 1..2, do: Task.async(fn -> Journal.dispatch(batch, "child-a") end)
    results = Enum.map(tasks, &Task.await(&1, 1_000))
    assert Enum.count(results, &match?({:ok, %Journal.Ticket{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :child_already_admitted})) == 1
  end

  test "completion joins in input order and survives restart with its generation", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger, child_id: child_id} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-order", ["first", "second"])
    identity = Journal.identity(batch)
    {:ok, first} = Journal.dispatch(batch, "first")
    {:ok, second} = Journal.dispatch(batch, "second")
    assert {:ok, _} = Journal.complete(second, %{value: 2})
    assert {:ok, _} = Journal.complete(first, %{value: 1})
    stop_supervised!(child_id)

    %{ledger: restarted} = start_ledger!(dir, id)
    {:ok, restored} = Journal.restore(restarted, identity)

    assert {:ok, %{results: [{"first", %{value: 1}}, {"second", %{value: 2}}]}} =
             Journal.join(restored)
  end

  test "a dispatched child remains pending after restart and cannot be redispatched", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger, child_id: child_id} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-pending", ["child-a"])
    identity = Journal.identity(batch)
    {:ok, _ticket} = Journal.dispatch(batch, "child-a")
    stop_supervised!(child_id)

    %{ledger: restarted} = start_ledger!(dir, id)
    {:ok, restored} = Journal.restore(restarted, identity)
    assert {:error, :child_already_admitted} = Journal.dispatch(restored, "child-a")

    assert {:ok, %{packet: %{"children" => [%{"state" => "dispatched"}]}}} =
             Journal.read(restored)
  end

  test "forged and conflicting results are rejected while an exact retry is idempotent", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-conflict", ["child-a"])
    {:ok, ticket} = Journal.dispatch(batch, "child-a")

    forged = %Journal.Ticket{
      batch: batch,
      id: "child-a",
      attempt: "00000000000000000000000000000000"
    }

    assert {:error, :child_result_conflict} = Journal.complete(forged, :forged)
    assert {:ok, _} = Journal.complete(ticket, :accepted)
    assert {:ok, _} = Journal.complete(ticket, :accepted)
    assert {:error, :child_result_conflict} = Journal.complete(ticket, :different)
  end

  test "skip only admits planned children", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-skip", ["planned", "dispatched"])
    {:ok, ticket} = Journal.dispatch(batch, "dispatched")
    assert {:ok, _} = Journal.skip(batch, "planned", :cancelled)
    assert {:error, :child_already_admitted} = Journal.skip(batch, "planned", :again)
    assert {:error, :child_already_admitted} = Journal.skip(batch, "dispatched", :cancelled)
    assert {:ok, _} = Journal.complete(ticket, :done)
  end

  test "stale acknowledgement is fenced and retirement allows eviction and key reuse", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger} = start_ledger!(dir, id, max_ops: 1)
    batch = open!(ledger, "batch-retire", ["child-a"])
    {:ok, ticket} = Journal.dispatch(batch, "child-a")
    assert {:ok, _} = Journal.complete(ticket, :done)
    {:ok, joined} = Journal.join(batch)

    assert {:error, :invalid_or_stale_join} =
             Journal.acknowledge(batch, joined.revision - 1, %{"saved" => true})

    assert {:error, :ledger_full} = Journal.open(ledger, "overflow-before-ack", ["child-a"])
    {:ok, acknowledged} = Journal.acknowledge(batch, joined.revision, %{"saved" => true})
    assert {:error, :ledger_full} = Journal.open(ledger, "overflow-after-ack", ["child-a"])
    assert :ok = Journal.retire(batch, acknowledged.revision)
    assert {:ok, retired} = Journal.read(batch)
    assert retired.state == :retired

    evict_batch = open!(ledger, "evict-retired", ["child-a"])
    {:ok, evict_ticket} = Journal.dispatch(evict_batch, "child-a")
    assert {:ok, _} = Journal.complete(evict_ticket, :done)
    {:ok, evict_joined} = Journal.join(evict_batch)

    {:ok, evict_acknowledged} =
      Journal.acknowledge(evict_batch, evict_joined.revision, %{"saved" => true})

    assert :ok = Journal.retire(evict_batch, evict_acknowledged.revision)
    reused = open!(ledger, "batch-retire", ["child-a"])
    assert reused.generation != batch.generation
    assert {:error, :batch_generation_mismatch} = Journal.read(batch)
  end

  test "unavailable and full ledgers fail closed", %{dir: dir, id: id} do
    %{ledger: ledger, child_id: child_id} = start_ledger!(dir, id)
    stop_supervised!(child_id)

    assert {:error, {:subagent_journal_unavailable, _}} =
             Journal.open(ledger, "unavailable", ["child-a"])

    %{ledger: full} = start_ledger!(dir, id <> "-full", max_ops: 1)
    _ = open!(full, "held", ["child-a"])
    assert {:error, :ledger_full} = Journal.open(full, "overflow", ["child-a"])
  end

  test "interrupted retirement resumes from the exact retire decision after restart", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger, child_id: child_id} = start_ledger!(dir, id)
    batch = open!(ledger, "batch-interrupted-retire", ["child-a"])
    {:ok, ticket} = Journal.dispatch(batch, "child-a")
    assert {:ok, _} = Journal.complete(ticket, :done)
    {:ok, joined} = Journal.join(batch)
    {:ok, acknowledged} = Journal.acknowledge(batch, joined.revision, %{"saved" => true})

    {:ok, resumed} =
      OperationLog.resume_checkpoint(ledger, "batch-interrupted-retire", acknowledged.revision, %{
        "action" => "retire-batch",
        "generation" => batch.generation
      })

    stop_supervised!(child_id)
    %{ledger: restarted} = start_ledger!(dir, id)
    {:ok, restored} = Journal.restore(restarted, Journal.identity(batch))
    assert {:ok, %{state: :retiring, revision: revision}} = Journal.read(restored)
    assert revision == resumed.revision
    assert :ok = Journal.retire(restored, revision)
    assert {:ok, %{state: :retired}} = Journal.read(restored)
    assert 2 == OperationLog.attempts(restarted, "batch-interrupted-retire")
  end

  test "nonportable and oversized results never replace the dispatched state", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "bounds", ["worker"])
    {:ok, ticket} = Journal.dispatch(batch, "worker")
    before = Journal.read(batch)
    assert {:error, :checkpoint_not_portable_or_too_large} = Journal.complete(ticket, self())

    assert {:error, :checkpoint_not_portable_or_too_large} =
             Journal.complete(ticket, [1 | :improper])

    assert {:error, {:child_result_too_large, 64_000}} =
             Journal.complete(ticket, String.duplicate("x", 65_000))

    assert Journal.read(batch) == before
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
      |> Enum.map(fn _ -> Task.async(fn -> Journal.open(ledger, "many", ids) end) end)
      |> Enum.map(&Task.await(&1, 2_000))

    assert Enum.all?(batches, &match?({:ok, %Journal{}}, &1))
    [{:ok, batch} | _] = batches
    assert Enum.all?(batches, fn {:ok, opened} -> opened.generation == batch.generation end)

    results =
      ids
      |> Enum.map(fn child ->
        Task.async(fn ->
          with {:ok, ticket} <- Journal.dispatch(batch, child),
               do: Journal.complete(ticket, child)
        end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert {:ok, joined} = Journal.join(batch)
    assert joined.results == Enum.map(ids, &{&1, &1})
    assert OperationLog.attempts(ledger, "many") == 1
  end

  test "approval decisions and grants are fenced independently from sibling changes", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger} = start_ledger!(dir, id)
    batch = open!(ledger, "approval-batch", ["one", "two"])
    {:ok, one} = Journal.dispatch(batch, "one")
    {:ok, two} = Journal.dispatch(batch, "two")
    checkpoint = %{"kind" => "child", "request" => %{"tool" => "write"}, "state" => "opaque"}
    assert {:ok, _} = Journal.suspend(one, checkpoint)
    assert {:ok, _} = Journal.suspend(two, checkpoint)
    assert {:ok, [%{identity: first}, %{identity: second}]} = Journal.suspended(batch)
    {:ok, viewed} = Journal.read(batch)
    assert {:ok, _} = Journal.decide(batch, viewed.revision, first, :approve)
    assert {:error, :stale_child_decision} = Journal.decide(batch, viewed.revision, second, :deny)
    {:ok, viewed} = Journal.read(batch)
    assert {:ok, _} = Journal.decide(batch, viewed.revision, second, :deny)
    tasks = for _ <- 1..2, do: Task.async(fn -> Journal.claim_child(batch, first, :approve) end)
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :child_resume_not_granted})) == 1
    assert {:error, :child_result_conflict} = Journal.complete(one, %{value: "stale worker"})

    assert {:ok, _} =
             Journal.complete(
               Enum.find_value(results, fn
                 {:ok, ticket} -> ticket
                 _ -> nil
               end),
               %{value: "approved"}
             )

    assert {:ok, second_ticket} = Journal.claim_child(batch, second, :deny)
    assert {:ok, _} = Journal.complete(second_ticket, %{value: "denied"})

    assert {:ok, %{results: [{"one", %{value: "approved"}}, {"two", %{value: "denied"}}]}} =
             Journal.join(batch)
  end
end
