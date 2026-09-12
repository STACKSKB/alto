defmodule Alto.Subagents.ContinuationTest do
  use ExUnit.Case, async: true

  alias Alto.OperationLog
  alias Alto.Subagents.Continuation

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-continuation-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, id: "continuation-#{System.unique_integer([:positive])}"}
  end

  defp start_ledger!(dir, id, opts \\ []) do
    child_id = {:continuation_ledger, id}

    ledger =
      start_supervised!({OperationLog, Keyword.merge([id: id, dir: dir, name: nil], opts)},
        id: child_id
      )

    %{ledger: ledger, child_id: child_id}
  end

  defp metadata do
    %{"journal" => %{"key" => "children", "generation" => String.duplicate("a", 32)}}
  end

  defp open!(ledger, key, pending \\ %{"frame" => "pending"}) do
    {:ok, cell} = Continuation.open(ledger, key, pending, metadata())
    cell
  end

  test "pending, ready, and claimed frames survive separate restarts", %{dir: dir, id: id} do
    %{ledger: ledger, child_id: child_id} = start_ledger!(dir, id)
    pending = %{"frame" => "parent", "position" => 3}
    ready = %{"frame" => "post-join", "children" => [%{"id" => "one", "result" => 1}]}
    cell = open!(ledger, "parent", pending)
    identity = Continuation.identity(cell)

    assert {:ok, %{revision: pending_revision, phase: :pending, packet: ^pending}} =
             Continuation.read(cell)

    stop_supervised!(child_id)
    %{ledger: restarted, child_id: child_id} = start_ledger!(dir, id)
    {:ok, cell} = Continuation.restore(restarted, identity)

    assert {:ok, %{phase: :pending, packet: ^pending, revision: ^pending_revision}} =
             Continuation.read(cell)

    assert {:ok, %{revision: ready_revision, phase: :ready, packet: ^ready}} =
             Continuation.ready(cell, pending_revision, ready)

    stop_supervised!(child_id)
    %{ledger: restarted, child_id: child_id} = start_ledger!(dir, id)
    {:ok, cell} = Continuation.restore(restarted, identity)

    assert {:ok, %{phase: :ready, packet: ^ready, metadata: saved_metadata}} =
             Continuation.read(cell)

    assert saved_metadata == metadata()

    assert {:ok, %{revision: claimed_revision, phase: :claimed, packet: ^ready}} =
             Continuation.claim(cell, ready_revision)

    assert claimed_revision > ready_revision
    stop_supervised!(child_id)
    %{ledger: restarted} = start_ledger!(dir, id)
    {:ok, cell} = Continuation.restore(restarted, identity)

    assert {:ok, %{phase: :claimed, packet: ^ready, revision: ^claimed_revision}} =
             Continuation.read(cell)

    assert {:error, :continuation_already_claimed} = Continuation.claim(cell, claimed_revision)
    assert OperationLog.attempts(restarted, "parent") == 1
  end

  test "a race grants exactly one claim", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id)
    cell = open!(ledger, "race")
    {:ok, pending} = Continuation.read(cell)
    {:ok, ready} = Continuation.ready(cell, pending.revision, %{"frame" => "post-join"})

    results =
      for _ <- 1..8 do
        Task.async(fn -> Continuation.claim(cell, ready.revision) end)
      end
      |> Enum.map(&Task.await(&1, 2_000))

    assert Enum.count(results, &match?({:ok, %{phase: :claimed}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_revision})) == 7
    assert {:ok, %{phase: :claimed}} = Continuation.read(cell)
  end

  test "stale revision, old generation, and repeated transitions cannot mutate state", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger} = start_ledger!(dir, id)
    cell = open!(ledger, "fences")
    {:ok, pending} = Continuation.read(cell)

    assert {:error, :stale_revision} =
             Continuation.ready(cell, pending.revision - 1, %{"frame" => "ready"})

    assert {:error, :invalid_continuation_revision} =
             Continuation.ready(cell, 0, %{"frame" => "ready"})

    assert {:error, :invalid_continuation_phase} = Continuation.claim(cell, pending.revision)
    assert Continuation.read(cell) == {:ok, pending}

    {:ok, ready} = Continuation.ready(cell, pending.revision, %{"frame" => "ready"})

    assert {:error, :continuation_already_ready} =
             Continuation.ready(cell, ready.revision, %{"frame" => "different"})

    assert Continuation.read(cell) == {:ok, ready}
    {:ok, claimed} = Continuation.claim(cell, ready.revision)
    assert {:error, :continuation_already_claimed} = Continuation.claim(cell, claimed.revision)
    assert Continuation.read(cell) == {:ok, claimed}

    wrong = %{Continuion_identity: "unused"}
    assert {:error, :invalid_continuation_identity} = Continuation.restore(ledger, wrong)

    old_identity = %{Continuation.identity(cell) | "generation" => String.duplicate("b", 32)}

    assert {:error, :continuation_generation_mismatch} =
             Continuation.restore(ledger, old_identity)
  end

  test "open converges on one plan and restore never creates", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id, max_ops: 1)
    pending = %{"frame" => "parent"}

    tasks =
      for _ <- 1..4,
          do: Task.async(fn -> Continuation.open(ledger, "same", pending, metadata()) end)

    results = Enum.map(tasks, &Task.await(&1, 2_000))
    assert Enum.all?(results, &match?({:ok, %Continuation{}}, &1))
    generations = for {:ok, cell} <- results, do: cell.generation
    assert length(Enum.uniq(generations)) == 1

    assert {:error, :continuation_plan_conflict} =
             Continuation.open(ledger, "same", %{"frame" => "changed"}, metadata())

    assert {:error, :ledger_full} =
             Continuation.open(ledger, "different", pending, metadata())

    missing = %{"key" => "missing", "generation" => hd(generations)}
    assert {:error, :not_found} = Continuation.restore(ledger, missing)
    assert OperationLog.attempts(ledger, "same") == 1
  end

  test "invalid packets and metadata fail without changing the retained frame", %{
    dir: dir,
    id: id
  } do
    %{ledger: ledger} = start_ledger!(dir, id)
    cell = open!(ledger, "bounds")
    {:ok, before} = Continuation.read(cell)

    for invalid <- [
          self(),
          %{"pid" => self()},
          %{"atom-key" => %{atom: 1}},
          %{"huge" => String.duplicate("x", 2_000_000)}
        ] do
      assert {:error, :continuation_packet_not_portable_or_too_large} =
               Continuation.ready(cell, before.revision, invalid)
    end

    assert Continuation.read(cell) == {:ok, before}

    assert {:error, :invalid_continuation_metadata} =
             Continuation.open(ledger, "bad-meta", %{"frame" => 1}, %{})

    assert {:error, :invalid_continuation_metadata} =
             Continuation.open(
               ledger,
               "bad-meta",
               %{"frame" => 1},
               Map.put(metadata(), "padding", String.duplicate("x", 65_000))
             )

    assert {:error, :continuation_packet_not_portable_or_too_large} =
             Continuation.open(
               ledger,
               "bad-packet",
               %{"huge" => String.duplicate("x", 2_000_000)},
               metadata()
             )

    assert {:error, :not_found} = OperationLog.recovery(ledger, "bad-meta")
    assert {:error, :not_found} = OperationLog.recovery(ledger, "bad-packet")
  end

  test "large frames use a compact immutable intent", %{dir: dir, id: id} do
    %{ledger: ledger} =
      start_ledger!(dir, id, max_recovery_bytes: 2_100_000, max_record_bytes: 2_500_000)

    pending = %{"frame" => String.duplicate("p", 1_900_000)}
    ready = %{"frame" => String.duplicate("r", 1_900_000)}
    cell = open!(ledger, "large", pending)
    {:ok, entry} = OperationLog.recovery(ledger, "large")

    assert :erlang.external_size(entry.recovery) < 1_000

    assert {:ok, %{phase: :pending, packet: ^pending, revision: revision}} =
             Continuation.read(cell)

    assert {:ok, %{phase: :ready, packet: ^ready}} =
             Continuation.ready(cell, revision, ready)
  end

  test "expired deadlines and foreign retained records fail closed", %{dir: dir, id: id} do
    %{ledger: ledger} = start_ledger!(dir, id)
    past = System.monotonic_time(:millisecond) - 1

    assert {:error, :run_timeout} =
             Continuation.open(ledger, "deadline", %{"frame" => 1}, metadata(), deadline: past)

    assert {:error, :not_found} = OperationLog.recovery(ledger, "deadline")
    cell = open!(ledger, "valid")

    assert {:error, :run_timeout} =
             Continuation.restore(ledger, Continuation.identity(cell), deadline: past)

    assert :ok = OperationLog.record_intent(ledger, "foreign", "other_kind", nil, %{})

    assert {:error, :invalid_continuation} =
             Continuation.restore(ledger, %{"key" => "foreign", "generation" => cell.generation})
  end
end
