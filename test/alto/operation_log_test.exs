defmodule Alto.OperationLogTest do
  @moduledoc """
  Operation fencing, atomic retained transitions, bounds, and durable replay.
  Consumer crash recovery is exercised through real workers in ConsumerTest.
  """

  use ExUnit.Case, async: true

  alias Alto.OperationLog

  defp entry_keys(entries), do: Enum.map(entries, & &1.operation_key)

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-ledger-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, id: "l" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  test "zero capacity rejects admission without creating entries", %{
    dir: dir,
    id: id
  } do
    {:ok, ledger} = OperationLog.start_link(id: id, dir: dir, name: nil, max_ops: 0)
    assert {:error, :ledger_full} = OperationLog.record_intent(ledger, "op", "tool", nil)

    assert {:error, :ledger_full} =
             OperationLog.retain(ledger, "cell", "internal", %{}, "init", %{})

    assert OperationLog.entries(ledger) == []
  end

  defp start_ledger!(opts) do
    name = :"ledger_#{System.unique_integer([:positive])}"
    {:ok, pid} = OperationLog.start_link(Keyword.put(opts, :name, name))
    %{pid: pid, name: name}
  end

  test "a second owner of the same log is refused while the first is alive", %{dir: dir, id: id} do
    %{pid: pid} = start_ledger!(id: id, dir: dir)

    assert {:error, :timeout} =
             OperationLog.start_link(id: id, dir: dir, name: unique_id(), lock_timeout: 50)

    GenServer.stop(pid)
  end

  test "rejects an append that would exceed the configured log byte bound", %{dir: dir, id: id} do
    %{name: name} = start_ledger!(id: id, dir: dir, max_log_bytes: 20)

    assert {:error, {:ledger_log_too_large, projected, 20}} =
             OperationLog.record_intent(name, "op-1", "tool", nil)

    assert projected > 20

    assert {:error, {:ledger_log_too_large, _, 20}} =
             OperationLog.retain(name, "cell", "internal", %{}, "init", %{})

    assert :no_intent = OperationLog.status(name, "cell")
    assert File.stat!(Path.join(dir, id <> ".jsonl")).size == 0
  end

  test "retained initialization is one durable command and never overwrites an existing record",
       %{dir: dir, id: id} do
    %{name: name, pid: pid} = start_ledger!(id: id, dir: dir)
    packet = %{count: 0}
    assert :ok = OperationLog.retain(name, "cell", "counter", %{limit: 3}, "init", packet)

    assert {:ok, %{revision: 1, checkpoint: ^packet, attempts: 1} = original} =
             OperationLog.recovery(name, "cell")

    path = Path.join(dir, id <> ".jsonl")
    bytes = File.read!(path)
    assert length(String.split(bytes, "\n", trim: true)) == 1
    assert :ok = OperationLog.retain(name, "cell", "other", %{}, "new", %{count: 99})
    assert File.read!(path) == bytes
    assert {:ok, ^original} = OperationLog.recovery(name, "cell")
    GenServer.stop(pid)
    %{name: replayed} = start_ledger!(id: id, dir: dir)
    assert {:ok, ^original} = OperationLog.recovery(replayed, "cell")
  end

  test "checkpoint retirement publishes all transitions or none", %{dir: dir, id: id} do
    %{name: name, pid: pid} = start_ledger!(id: id, dir: dir)
    assert :ok = OperationLog.retain(name, "cell", "counter", %{}, "init", %{count: 2})
    {:ok, before} = OperationLog.recovery(name, "cell")
    path = Path.join(dir, id <> ".jsonl")
    bytes = File.read!(path)
    decision = %{action: :close}
    evidence = %{count: 2}

    assert {:error, {:invalid_attempt, ""}} =
             OperationLog.retire_checkpoint(name, "cell", 1, decision, "", evidence)

    assert {:ok, ^before} = OperationLog.recovery(name, "cell")
    assert File.read!(path) == bytes

    max_bytes = :sys.get_state(name).max_log_bytes
    :sys.replace_state(name, &%{&1 | max_log_bytes: byte_size(bytes) + 1})

    assert {:error, {:ledger_log_too_large, _, _}} =
             OperationLog.retire_checkpoint(name, "cell", 1, decision, "close", evidence)

    assert {:ok, ^before} = OperationLog.recovery(name, "cell")
    assert File.read!(path) == bytes

    :sys.replace_state(name, &%{&1 | max_log_bytes: max_bytes})
    assert :ok = OperationLog.retire_checkpoint(name, "cell", 1, decision, "close", evidence)

    assert {:ok, %{revision: 2, attempts: 2, checkpoint_decision: ^decision} = closed} =
             OperationLog.recovery(name, "cell")

    assert closed.status == {:decided, :completed, evidence}
    assert length(String.split(File.read!(path), "\n", trim: true)) == 2

    assert {:error, :stale_revision} =
             OperationLog.retire_checkpoint(name, "cell", 1, decision, "close", evidence)

    GenServer.stop(pid)
    %{name: restarted} = start_ledger!(id: id, dir: dir)
    assert {:ok, ^closed} = OperationLog.recovery(restarted, "cell")
  end

  defp unique_id, do: String.to_atom("ledger_test_#{System.unique_integer([:positive])}")

  describe "lifecycle" do
    test "attempt reservation is atomic under competing owners", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir)
      :ok = OperationLog.record_intent(name, "op-1", "print", nil)
      parent = self()

      tasks =
        for attempt <- ["owner-a", "owner-b"] do
          Task.async(fn ->
            receive do
              :go -> :ok
            end

            send(
              parent,
              {:reservation, attempt, OperationLog.record_attempt(name, "op-1", attempt)}
            )
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))

      results =
        for _ <- tasks do
          assert_receive {:reservation, attempt, result}
          {attempt, result}
        end

      assert 1 == Enum.count(results, fn {_attempt, result} -> result == :ok end)

      assert 1 ==
               Enum.count(results, fn {_attempt, result} ->
                 result == {:error, :attempt_in_flight}
               end)

      Enum.each(tasks, &Task.await/1)
    end

    test "an older attempt cannot overwrite the current decision", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir)
      :ok = OperationLog.record_intent(name, "op-1", "print", nil)
      :ok = OperationLog.record_attempt(name, "op-1", "old")
      :ok = OperationLog.record_release(name, "op-1", "old")
      :ok = OperationLog.record_attempt(name, "op-1", "new")
      :ok = OperationLog.record_outcome(name, "op-1", "new", :requires_operator)

      assert {:error, :already_decided} =
               OperationLog.record_outcome(name, "op-1", "old", :completed)
    end

    test "intent, attempt, outcome drive the recovery status", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir)

      assert :no_intent = OperationLog.status(name, "op-1")
      assert 0 = OperationLog.attempts(name, "op-1")

      assert :ok = OperationLog.record_intent(name, "op-1", "print", "inbox:del-1")
      assert {:intended} = OperationLog.status(name, "op-1")

      assert :ok = OperationLog.record_attempt(name, "op-1", "clm-a")
      assert {:dispatched, "clm-a"} = OperationLog.status(name, "op-1")
      assert 1 = OperationLog.attempts(name, "op-1")

      assert :ok = OperationLog.record_outcome(name, "op-1", "clm-a", :completed, %{pages: 2})
      assert {:decided, :completed, %{pages: 2}} = OperationLog.status(name, "op-1")
    end

    test "ordering is enforced: no intent skipping", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir)

      assert {:error, :no_intent} = OperationLog.record_attempt(name, "ghost", "clm-a")

      assert {:error, :no_intent} =
               OperationLog.record_outcome(name, "ghost", "clm-a", :completed, %{})

      assert :ok = OperationLog.record_intent(name, "op-1", "print", nil)

      assert {:error, :no_attempt} =
               OperationLog.record_outcome(name, "op-1", "clm-a", :completed, %{})
    end

    test "intent and attempt are idempotent; unknown outcomes can only escalate", %{
      dir: dir,
      id: id
    } do
      %{name: name} = start_ledger!(id: id, dir: dir)

      assert :ok = OperationLog.record_intent(name, "op-1", "print", nil)
      assert :ok = OperationLog.record_intent(name, "op-1", "print", nil)
      assert {:intended} = OperationLog.status(name, "op-1")

      assert :ok = OperationLog.record_attempt(name, "op-1", "clm-a")
      assert :ok = OperationLog.record_attempt(name, "op-1", "clm-a")
      assert 1 = OperationLog.attempts(name, "op-1")

      assert :ok = OperationLog.record_outcome(name, "op-1", "clm-a", :unknown, %{})

      assert {:error, :already_decided} =
               OperationLog.record_outcome(name, "op-1", "clm-a", :completed, %{note: "op"})

      assert {:decided, :unknown, %{}} = OperationLog.status(name, "op-1")
      assert :ok = OperationLog.record_outcome(name, "op-1", "clm-a", :requires_operator, %{})
      assert {:decided, :requires_operator, %{}} = OperationLog.status(name, "op-1")
    end

    test "an operation identity cannot be rebound to different accepted work", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir)
      recovery = %{generation_id: "gen-a", key: "job-1", payload: %{v: 1}}

      assert :ok = OperationLog.record_intent(name, "op-1", "print", "job-1", recovery)
      assert :ok = OperationLog.record_intent(name, "op-1", "print", "job-1", recovery)

      assert {:error, :intent_conflict} =
               OperationLog.record_intent(
                 name,
                 "op-1",
                 "print",
                 "job-1",
                 %{recovery | payload: %{v: 1.0}}
               )

      assert {:error, :intent_conflict} =
               OperationLog.record_intent(
                 name,
                 "op-1",
                 "print",
                 "job-1",
                 %{recovery | generation_id: "gen-b"}
               )
    end

    test "invalid classes, evidence, and keys fail closed", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir)
      :ok = OperationLog.record_intent(name, "op-1", "t", nil)

      assert {:error, {:invalid_outcome_class, :bogus}} =
               OperationLog.record_outcome(name, "op-1", "clm-a", :bogus, %{})

      assert {:error, {:invalid_evidence, []}} =
               OperationLog.record_outcome(name, "op-1", "clm-a", :completed, [])

      assert {:error, {:invalid_op_key, ""}} = OperationLog.record_intent(name, "", "t", nil)
      assert {:error, {:invalid_attempt, ""}} = OperationLog.record_attempt(name, "op-1", "")
    end

    test "canonical entries preserve order, filters, and fields across restart", %{
      dir: dir,
      id: id
    } do
      ledger_dir = Path.join(dir, "l")
      %{name: name, pid: pid} = start_ledger!(id: id, dir: ledger_dir)

      :ok = OperationLog.record_intent(name, "op-a", "t", nil)
      :ok = OperationLog.record_intent(name, "op-b", "t", nil)
      :ok = OperationLog.record_attempt(name, "op-b", "clm-1")
      :ok = OperationLog.record_intent(name, "op-c", "t", nil)
      :ok = OperationLog.record_attempt(name, "op-c", "clm-2")
      :ok = OperationLog.record_outcome(name, "op-c", "clm-2", :completed, %{})

      assert ["op-a", "op-b"] = entry_keys(OperationLog.entries(name, :open))
      assert [] = entry_keys(OperationLog.entries(name, :parked))

      assert [first, second, third] = OperationLog.entries(name)
      assert {first.operation_key, first.status, first.attempts} == {"op-a", {:intended}, 0}

      assert {second.operation_key, second.status, second.attempts} ==
               {"op-b", {:dispatched, "clm-1"}, 1}

      assert {third.operation_key, third.status, third.attempts} ==
               {"op-c", {:decided, :completed, %{}}, 1}

      GenServer.stop(pid)
      %{name: restarted} = start_ledger!(id: id, dir: ledger_dir)
      assert OperationLog.entries(restarted) == [first, second, third]
    end

    test "a released attempt returns to intended; parked work lists for operators", %{
      dir: dir,
      id: id
    } do
      %{name: name} = start_ledger!(id: id, dir: Path.join(dir, "l"))

      :ok = OperationLog.record_intent(name, "op-1", "t", nil)
      :ok = OperationLog.record_attempt(name, "op-1", "clm-a")
      assert {:dispatched, "clm-a"} = OperationLog.status(name, "op-1")

      assert {:error, :no_attempt} = OperationLog.record_release(name, "op-1", "clm-ghost")
      assert :ok = OperationLog.record_release(name, "op-1", "clm-a")
      assert {:intended} = OperationLog.status(name, "op-1")
      assert 1 = OperationLog.attempts(name, "op-1")

      # Healthy retry-in-flight is not operator work.
      assert [] = entry_keys(OperationLog.entries(name, :open))

      :ok = OperationLog.record_attempt(name, "op-1", "clm-b")
      assert {:dispatched, "clm-b"} = OperationLog.status(name, "op-1")
      assert ["op-1"] = entry_keys(OperationLog.entries(name, :open))

      :ok = OperationLog.record_outcome(name, "op-1", "clm-b", :requires_operator, %{why: "x"})
      assert ["op-1"] = entry_keys(OperationLog.entries(name, :parked))
      assert [] = entry_keys(OperationLog.entries(name, :open))
    end

    test "closed and historical owners cannot release or reserve again", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir)
      :ok = OperationLog.record_intent(name, "op-1", "t", nil)
      :ok = OperationLog.record_attempt(name, "op-1", "old")
      :ok = OperationLog.record_release(name, "op-1", "old")
      assert {:error, :stale_attempt} = OperationLog.record_attempt(name, "op-1", "old")

      :ok = OperationLog.record_attempt(name, "op-1", "new")
      assert {:error, :stale_attempt} = OperationLog.record_release(name, "op-1", "old")
      :ok = OperationLog.record_outcome(name, "op-1", "new", :completed)
      assert {:error, :already_decided} = OperationLog.record_release(name, "op-1", "new")
    end
  end

  describe "secrets and bounds" do
    test "max_ops admission atomically evicts one terminal entry and never exceeds capacity", %{
      dir: dir,
      id: id
    } do
      %{name: name, pid: pid} = start_ledger!(id: id, dir: dir, max_ops: 1)
      :ok = OperationLog.record_intent(name, "seed", "t", nil)
      :ok = OperationLog.record_attempt(name, "seed", "a")
      :ok = OperationLog.record_outcome(name, "seed", "a", :completed)

      assert :ok = OperationLog.record_intent(name, "new", "t", nil)
      assert :no_intent = OperationLog.status(name, "seed")
      assert {:error, :ledger_full} = OperationLog.record_intent(name, "overflow", "t", nil)
      assert map_size(:sys.get_state(pid).ops) == 1

      GenServer.stop(pid)
      %{name: restarted} = start_ledger!(id: id, dir: dir, max_ops: 1)
      assert {:intended} = OperationLog.status(restarted, "new")
    end

    test "reusing an evicted key replays the same state after restart", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_ledger!(id: id, dir: dir, max_ops: 1)

      for {key, attempt} <- [{"a", "a-1"}, {"b", "b-1"}] do
        :ok = OperationLog.record_intent(name, key, "t", nil)
        :ok = OperationLog.record_attempt(name, key, attempt)
        :ok = OperationLog.record_outcome(name, key, attempt, :completed)
      end

      assert :no_intent = OperationLog.status(name, "a")
      reuse = %{generation_id: "reuse-a", key: "a", payload: %{version: 2}}
      :ok = OperationLog.record_intent(name, "a", "t-reuse", "a", reuse)
      :ok = OperationLog.record_attempt(name, "a", "a-2")
      :ok = OperationLog.record_outcome(name, "a", "a-2", :failed_known)
      assert {:ok, live} = OperationLog.recovery(name, "a")

      GenServer.stop(pid)
      %{name: restarted} = start_ledger!(id: id, dir: dir, max_ops: 1)
      assert {:error, :not_found} = OperationLog.recovery(restarted, "b")

      assert {:ok, ^live} = OperationLog.recovery(restarted, "a")
    end

    test "restart refuses unresolved state above the configured capacity", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_ledger!(id: id, dir: dir, max_ops: 2)
      :ok = OperationLog.record_intent(name, "open-a", "t", nil)
      :ok = OperationLog.record_intent(name, "open-b", "t", nil)
      GenServer.stop(pid)

      assert {:error, {:ledger_capacity_exceeded, 2, 1}} =
               OperationLog.start_link(id: id, dir: dir, name: nil, max_ops: 1)
    end

    test "evidence and record byte limits fail before append", %{dir: dir, id: id} do
      %{name: name} =
        start_ledger!(id: id, dir: dir, max_evidence_bytes: 64, max_record_bytes: 512)

      :ok = OperationLog.record_intent(name, "op-1", "t", nil)
      :ok = OperationLog.record_attempt(name, "op-1", "a")
      path = Path.join(dir, id <> ".jsonl")
      acknowledged_bytes = File.read!(path)

      assert {:error, {:evidence_too_large, 64}} =
               OperationLog.record_outcome(name, "op-1", "a", :completed, %{
                 detail: String.duplicate("x", 500)
               })

      assert File.read!(path) == acknowledged_bytes
      assert {:dispatched, "a"} = OperationLog.status(name, "op-1")

      %{name: small_record} =
        start_ledger!(
          id: id <> "small",
          dir: Path.join(dir, "small"),
          max_recovery_bytes: 1_000,
          max_record_bytes: 180
        )

      assert {:error, {:record_too_large, size, 180}} =
               OperationLog.record_intent(
                 small_record,
                 "op-2",
                 "t",
                 nil,
                 %{payload: String.duplicate("y", 100)}
               )

      assert size > 180
      assert :no_intent = OperationLog.status(small_record, "op-2")
    end

    test "runtime capabilities cannot enter the durable command stream", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir)

      assert {:error, {:ledger_unencodable, :not_portable}} =
               OperationLog.record_intent(name, "op", "tool", nil, %{callback: fn -> :ok end})

      assert :no_intent = OperationLog.status(name, "op")
      assert File.read!(Path.join(dir, id <> ".jsonl")) == ""
    end

    test "identifier and attempt-history limits are enforced and replayed", %{dir: dir, id: id} do
      %{name: name, pid: pid} =
        start_ledger!(id: id, dir: dir, max_identifier_bytes: 8, max_attempts: 1)

      assert {:error, {:identifier_too_large, :tool, 8}} =
               OperationLog.record_intent(name, "op", "tool-name-too-long", nil)

      :ok = OperationLog.record_intent(name, "op", "t", nil)
      :ok = OperationLog.record_attempt(name, "op", "first")
      :ok = OperationLog.record_release(name, "op", "first")
      assert {:error, :attempt_history_full} = OperationLog.record_attempt(name, "op", "second")
      GenServer.stop(pid)

      %{name: restarted} =
        start_ledger!(id: id, dir: dir, max_identifier_bytes: 8, max_attempts: 1)

      assert {:intended} = OperationLog.status(restarted, "op")
      assert 1 = OperationLog.attempts(restarted, "op")
    end

    test "credential-shaped evidence never reaches disk", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir)

      :ok = OperationLog.record_intent(name, "op-1", "tally", nil)
      :ok = OperationLog.record_attempt(name, "op-1", "clm-a")

      :ok =
        OperationLog.record_outcome(name, "op-1", "clm-a", :completed, %{
          "api_key" => "sk-live-123",
          :password => "hunter2",
          "document" => "inv-9"
        })

      assert {:decided, :completed, evidence} = OperationLog.status(name, "op-1")
      assert evidence["api_key"] == "[redacted]"
      assert evidence[:password] == "[redacted]"
      assert evidence["document"] == "inv-9"

      {:ok, bytes} = File.read(Path.join(dir, id <> ".jsonl"))
      refute bytes =~ "sk-live-123"
      refute bytes =~ "hunter2"

      encoded = bytes |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()

      assert {:ok, {:outcome, "op-1", "clm-a", :completed, ^evidence}} =
               Alto.Persistence.Codec.decode(encoded)
    end

    test "a full ledger of undecided work fails closed instead of forgetting", %{
      dir: dir,
      id: id
    } do
      %{name: name} = start_ledger!(id: id, dir: dir, max_ops: 1)

      assert :ok = OperationLog.record_intent(name, "op-1", "t", nil)
      assert {:error, :ledger_full} = OperationLog.record_intent(name, "op-2", "t", nil)

      # Decided work may leave to make room.
      assert :ok = OperationLog.record_attempt(name, "op-1", "clm-a")
      assert :ok = OperationLog.record_outcome(name, "op-1", "clm-a", :completed, %{})
      assert :ok = OperationLog.record_intent(name, "op-2", "t", nil)
    end
  end

  describe "durability" do
    test "valid final JSON without newline is repaired before the next append", %{
      dir: dir,
      id: id
    } do
      ledger_dir = Path.join(dir, "l")
      %{name: name, pid: pid} = start_ledger!(id: id, dir: ledger_dir)
      :ok = OperationLog.record_intent(name, "op-1", "t", nil)
      path = Path.join(ledger_dir, id <> ".jsonl")
      GenServer.stop(pid)
      File.write!(path, String.trim_trailing(File.read!(path), "\n"))

      %{name: name2, pid: pid2} = start_ledger!(id: id, dir: ledger_dir)
      :ok = OperationLog.record_attempt(name2, "op-1", "attempt-1")
      GenServer.stop(pid2)

      %{name: name3} = start_ledger!(id: id, dir: ledger_dir)
      assert {:dispatched, "attempt-1"} = OperationLog.status(name3, "op-1")
    end

    test "a failed append at capacity does not publish its planned eviction", %{dir: dir, id: id} do
      ledger_dir = Path.join(dir, "l")
      %{name: name} = start_ledger!(id: id, dir: ledger_dir, max_ops: 1)
      :ok = OperationLog.record_intent(name, "old", "t", nil)
      :ok = OperationLog.record_attempt(name, "old", "attempt-1")
      :ok = OperationLog.record_outcome(name, "old", "attempt-1", :completed)
      path = Path.join(ledger_dir, id <> ".jsonl")
      File.rm!(path)
      File.mkdir!(path)

      assert {:error, {:ledger_write_failed, :eisdir}} =
               OperationLog.record_intent(name, "new", "t", nil)

      assert {:decided, :completed, %{}} = OperationLog.status(name, "old")
      assert :no_intent = OperationLog.status(name, "new")
    end

    test "live lifecycle and replay produce the same recovery view", %{dir: dir, id: id} do
      ledger_dir = Path.join(dir, "l")
      %{name: name, pid: pid} = start_ledger!(id: id, dir: ledger_dir)
      :ok = OperationLog.record_intent(name, "op", "tool", "inbox", %{payload: 1})
      :ok = OperationLog.record_attempt(name, "op", "first")
      :ok = OperationLog.record_release(name, "op", "first")
      :ok = OperationLog.record_attempt(name, "op", "second")

      :ok =
        OperationLog.record_outcome(name, "op", "second", :unknown, %{"code" => 502, code: 503})

      assert {:ok, live} = OperationLog.recovery(name, "op")
      GenServer.stop(pid)

      %{name: replayed} = start_ledger!(id: id, dir: ledger_dir)
      assert {:ok, ^live} = OperationLog.recovery(replayed, "op")
    end

    test "state survives restart; torn tail is discarded", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_ledger!(id: id, dir: Path.join(dir, "l"))

      :ok = OperationLog.record_intent(name, "op-1", "t", nil)
      :ok = OperationLog.record_attempt(name, "op-1", "clm-a")
      GenServer.stop(pid)

      %{name: name2} = start_ledger!(id: id, dir: Path.join(dir, "l"))
      assert {:dispatched, "clm-a"} = OperationLog.status(name2, "op-1")

      path = Path.join([dir, "l", id <> ".jsonl"])
      File.write!(path, File.read!(path) <> ~s("torn))
      GenServer.stop(Process.whereis(name2))

      %{name: name3} = start_ledger!(id: id, dir: Path.join(dir, "l"))
      assert {:dispatched, "clm-a"} = OperationLog.status(name3, "op-1")
      assert :no_intent = OperationLog.status(name3, "op-torn")
    end

    test "malformed records fail startup", %{dir: dir, id: id} do
      path = Path.join([dir, "l", id <> ".jsonl"])
      File.mkdir_p!(Path.dirname(path))

      {:ok, unknown} = Alto.Persistence.Codec.encode({:unknown, "op"})
      {:ok, incomplete} = Alto.Persistence.Codec.encode({:intent, "op"})

      for {line, reason} <- [
            {JSON.encode!("invalid"), {:ledger_corrupt, id, 1}},
            {JSON.encode!(unknown), {:ledger_corrupt, id, 1}},
            {JSON.encode!(incomplete), {:ledger_corrupt, id, 1}},
            {"not json", {:ledger_corrupt, id, 1}}
          ] do
        File.write!(path, line <> "\n")

        assert {:error, ^reason} =
                 OperationLog.start_link(
                   id: id,
                   dir: Path.join(dir, "l"),
                   name: :"ledger_corrupt_#{System.unique_integer([:positive])}"
                 )
      end
    end
  end
end
