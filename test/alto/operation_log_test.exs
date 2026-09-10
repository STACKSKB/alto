defmodule Alto.OperationLogTest do
  @moduledoc """
  conformance: the bounded operation ledger.

  Intent precedes attempt precedes outcome by store enforcement; crash
  injection at every point leaves the ledger either actionable (intended),
  parked-for-reconciliation (dispatched without outcome), or decided —
  never an invented success.
  """

  use ExUnit.Case, async: true

  alias Alto.OperationLog
  alias Alto.Queue

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-ledger-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, id: "l" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  defp start_ledger!(opts) do
    name = :"ledger_#{System.unique_integer([:positive])}"
    {:ok, pid} = OperationLog.start_link(Keyword.put(opts, :name, name))
    %{pid: pid, name: name}
  end

  defp start_queue!(opts) do
    name = :"ledger_queue_#{System.unique_integer([:positive])}"
    {:ok, pid} = Queue.start_link(Keyword.put(opts, :name, name))
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
    assert File.stat!(Path.join(dir, id <> ".jsonl")).size == 0
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

    test "intent and attempt are idempotent; decisions are immutable", %{dir: dir, id: id} do
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
                 %{recovery | generation_id: "gen-b"}
               )
    end

    test "invalid classes, evidence, and keys fail closed", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir)

      assert {:error, {:invalid_outcome_class, :bogus}} =
               OperationLog.record_outcome(name, "op-1", "clm-a", :bogus, %{})

      assert {:error, {:invalid_evidence, []}} =
               OperationLog.record_outcome(name, "op-1", "clm-a", :completed, [])

      assert {:error, {:invalid_op_key, ""}} = OperationLog.record_intent(name, "", "t", nil)
      assert {:error, {:invalid_attempt, ""}} = OperationLog.record_attempt(name, "op-1", "")
    end

    test "list_open shows undecided work oldest first", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: Path.join(dir, "l"))

      :ok = OperationLog.record_intent(name, "op-a", "t", nil)
      :ok = OperationLog.record_intent(name, "op-b", "t", nil)
      :ok = OperationLog.record_attempt(name, "op-b", "clm-1")
      :ok = OperationLog.record_intent(name, "op-c", "t", nil)
      :ok = OperationLog.record_attempt(name, "op-c", "clm-2")
      :ok = OperationLog.record_outcome(name, "op-c", "clm-2", :completed, %{})

      assert ["op-a", "op-b"] = OperationLog.list_open(name)
      assert [] = OperationLog.list_parked(name)
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
      assert [] = OperationLog.list_open(name)

      :ok = OperationLog.record_attempt(name, "op-1", "clm-b")
      assert {:dispatched, "clm-b"} = OperationLog.status(name, "op-1")
      assert ["op-1"] = OperationLog.list_open(name)

      :ok = OperationLog.record_outcome(name, "op-1", "clm-b", :requires_operator, %{why: "x"})
      assert ["op-1"] = OperationLog.list_parked(name)
      assert [] = OperationLog.list_open(name)
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
      assert map_size(:sys.get_state(pid).ops) == 1
      assert :no_intent = OperationLog.status(name, "seed")
      assert {:error, :ledger_full} = OperationLog.record_intent(name, "overflow", "t", nil)
      assert map_size(:sys.get_state(pid).ops) == 1

      GenServer.stop(pid)
      %{name: restarted, pid: restarted_pid} = start_ledger!(id: id, dir: dir, max_ops: 1)
      assert {:intended} = OperationLog.status(restarted, "new")
      assert map_size(:sys.get_state(restarted_pid).ops) == 1
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

    test "parked work is retained while terminal work can be evicted", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir, max_ops: 2)
      :ok = OperationLog.record_intent(name, "parked", "t", nil)
      :ok = OperationLog.record_attempt(name, "parked", "a")
      :ok = OperationLog.record_outcome(name, "parked", "a", :requires_operator)
      :ok = OperationLog.record_intent(name, "done", "t", nil)
      :ok = OperationLog.record_attempt(name, "done", "b")
      :ok = OperationLog.record_outcome(name, "done", "b", :completed)
      assert ["parked"] = OperationLog.list_parked(name)
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
    end

    test "raw arguments are not stored: intent keeps identity only", %{dir: dir, id: id} do
      %{name: name} = start_ledger!(id: id, dir: dir)
      :ok = OperationLog.record_intent(name, "op-1", "print", "inbox:del-1")

      {:ok, bytes} = File.read(Path.join(dir, id <> ".jsonl"))
      assert bytes =~ "op-1"
      assert bytes =~ "print"
      refute bytes =~ "arguments"
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

  describe "crash injection against the inbox" do
    test "before intent: nothing recorded, recovery may start fresh", %{dir: dir, id: id} do
      %{name: q} = start_queue!(id: "q" <> id, dir: Path.join(dir, "q"))
      %{name: log} = start_ledger!(id: id, dir: Path.join(dir, "l"))

      {:ok, _} = Queue.admit(q, "src:del-1", %{"body" => "x"})
      # Crash before any ledger write.
      assert :no_intent = OperationLog.status(log, "src:del-1")

      # Recovery starts fresh under the same semantic identity.
      assert :ok = OperationLog.record_intent(log, "src:del-1", "pack", "src:del-1")
      assert {:intended} = OperationLog.status(log, "src:del-1")
    end

    test "after intent: recovery may dispatch", %{dir: dir, id: id} do
      %{name: log} = start_ledger!(id: id, dir: Path.join(dir, "l"))

      :ok = OperationLog.record_intent(log, "src:del-1", "pack", "src:del-1")
      # Crash after intent, before dispatch.
      assert {:intended} = OperationLog.status(log, "src:del-1")

      assert :ok = OperationLog.record_attempt(log, "src:del-1", "clm-a")
      assert {:dispatched, "clm-a"} = OperationLog.status(log, "src:del-1")
    end

    test "after remote commit with no recorded result: never decided, never rerun blindly", %{
      dir: dir,
      id: id
    } do
      %{name: log} = start_ledger!(id: id, dir: Path.join(dir, "l"))

      :ok = OperationLog.record_intent(log, "src:del-1", "print", "src:del-1")
      :ok = OperationLog.record_attempt(log, "src:del-1", "clm-a")
      # The participant committed, then the response was lost: no outcome line.
      status = OperationLog.status(log, "src:del-1")

      assert {:dispatched, "clm-a"} = status
      refute match?({:decided, _, _}, status)

      # Recovery parks for reconciliation under the same identity.
      assert :ok = OperationLog.record_outcome(log, "src:del-1", "clm-a", :unknown, %{})
      assert :ok = OperationLog.record_outcome(log, "src:del-1", "clm-a", :requires_operator, %{})
      assert {:decided, :requires_operator, _} = OperationLog.status(log, "src:del-1")
    end

    test "before inbox ack: decided outcome acks without re-running", %{dir: dir, id: id} do
      %{name: q} = start_queue!(id: "q" <> id, dir: Path.join(dir, "q"))
      %{name: log} = start_ledger!(id: id, dir: Path.join(dir, "l"))

      {:ok, _} = Queue.admit(q, "src:del-1", %{"body" => "x"})
      {:ok, [claimed]} = Queue.claim(q, 1, "worker-1")

      :ok = OperationLog.record_intent(log, "src:del-1", "pack", "src:del-1")
      :ok = OperationLog.record_attempt(log, "src:del-1", claimed.claim_id)
      # Work done, outcome recorded — crash before the ack.
      :ok = OperationLog.record_outcome(log, "src:del-1", claimed.claim_id, :completed, %{})

      # Recovery reads the decision and acks; no second dispatch exists.
      assert {:decided, :completed, _} = OperationLog.status(log, "src:del-1")
      assert :ok = Queue.ack(q, claimed.claim_id)
      assert %{pending: 0, claimed: 0} = Queue.count(q)
      # And the delivery stays deduped afterwards.
      assert {:error, :duplicate} = Queue.admit(q, "src:del-1", %{"body" => "x"})
    end

    test "no path invents success from a transcript-less dispatch", %{dir: dir, id: id} do
      %{name: log} = start_ledger!(id: id, dir: Path.join(dir, "l"))

      :ok = OperationLog.record_intent(log, "src:del-1", "print", "src:del-1")
      :ok = OperationLog.record_attempt(log, "src:del-1", "clm-a")

      # Whatever the recovery reads, it is not a decision.
      refute match?({:decided, :completed, _}, OperationLog.status(log, "src:del-1"))
      assert ["src:del-1"] = OperationLog.list_open(log)
    end
  end

  describe "durability" do
    test "compatible pre-recovery records replay without inventing input", %{dir: dir, id: id} do
      ledger_dir = Path.join(dir, "legacy")
      path = Path.join(ledger_dir, id <> ".jsonl")
      File.mkdir_p!(ledger_dir)

      entries = [
        %{"v" => 1, "t" => "intent", "op" => "legacy", "tool" => "t", "inbox" => nil},
        %{"v" => 1, "t" => "attempt", "op" => "legacy", "attempt" => "old-a"},
        %{
          "v" => 1,
          "t" => "outcome",
          "op" => "legacy",
          "attempt" => "old-a",
          "class" => "unknown",
          "evidence" => %{}
        }
      ]

      File.write!(path, Enum.map_join(entries, "", &(JSON.encode!(&1) <> "\n")))
      %{name: name} = start_ledger!(id: id, dir: ledger_dir)

      assert {:decided, :unknown, %{}} = OperationLog.status(name, "legacy")
      assert {:ok, %{recovery: nil}} = OperationLog.recovery(name, "legacy")
    end

    test "ambiguous historical owner transitions require migration review", %{dir: dir, id: id} do
      ledger_dir = Path.join(dir, "ambiguous")
      path = Path.join(ledger_dir, id <> ".jsonl")
      File.mkdir_p!(ledger_dir)

      entries = [
        %{"v" => 1, "t" => "intent", "op" => "op", "tool" => "t", "inbox" => nil},
        %{"v" => 1, "t" => "attempt", "op" => "op", "attempt" => "old"},
        %{"v" => 1, "t" => "release", "op" => "op", "attempt" => "old"},
        %{"v" => 1, "t" => "attempt", "op" => "op", "attempt" => "new"},
        %{
          "v" => 1,
          "t" => "outcome",
          "op" => "op",
          "attempt" => "new",
          "class" => "requires_operator",
          "evidence" => %{}
        },
        %{
          "v" => 1,
          "t" => "outcome",
          "op" => "op",
          "attempt" => "old",
          "class" => "completed",
          "evidence" => %{}
        }
      ]

      File.write!(path, Enum.map_join(entries, "", &(JSON.encode!(&1) <> "\n")))

      assert {:error, {:ledger_migration_required, ^id, "op", {:stale_outcome, "old"}}} =
               OperationLog.start_link(id: id, dir: ledger_dir, name: nil)
    end

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

    test "a failed append leaves acknowledged memory state unchanged", %{dir: dir, id: id} do
      ledger_dir = Path.join(dir, "l")
      %{name: name} = start_ledger!(id: id, dir: ledger_dir)
      :ok = OperationLog.record_intent(name, "op-1", "t", nil)
      path = Path.join(ledger_dir, id <> ".jsonl")
      File.rm!(path)
      File.mkdir!(path)

      assert {:error, {:ledger_write_failed, :eisdir}} =
               OperationLog.record_attempt(name, "op-1", "attempt-1")

      assert {:intended} = OperationLog.status(name, "op-1")
    end

    test "state survives restart; torn tail is discarded", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_ledger!(id: id, dir: Path.join(dir, "l"))

      :ok = OperationLog.record_intent(name, "op-1", "t", nil)
      :ok = OperationLog.record_attempt(name, "op-1", "clm-a")
      GenServer.stop(pid)

      %{name: name2} = start_ledger!(id: id, dir: Path.join(dir, "l"))
      assert {:dispatched, "clm-a"} = OperationLog.status(name2, "op-1")

      path = Path.join([dir, "l", id <> ".jsonl"])
      File.write!(path, File.read!(path) <> "{\"v\": 1, \"t\": \"intent\", \"op\": \"op-torn\"")
      GenServer.stop(Process.whereis(name2))

      %{name: name3} = start_ledger!(id: id, dir: Path.join(dir, "l"))
      assert {:dispatched, "clm-a"} = OperationLog.status(name3, "op-1")
      assert :no_intent = OperationLog.status(name3, "op-torn")
    end

    test "middle corruption fails the start loudly", %{dir: dir, id: id} do
      path = Path.join([dir, "l", id <> ".jsonl"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json\n")

      assert {:error, {:ledger_corrupt, ^id, 1}} =
               OperationLog.start_link(
                 id: id,
                 dir: Path.join(dir, "l"),
                 name: :"ledger_corrupt_#{System.unique_integer([:positive])}"
               )
    end
  end
end
