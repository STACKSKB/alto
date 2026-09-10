defmodule Alto.OperationLogCheckpointTest do
  use ExUnit.Case, async: true
  alias Alto.OperationLog

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto-checkpoint-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    name = String.to_atom("checkpoint_" <> Integer.to_string(System.unique_integer([:positive])))
    {:ok, _} = OperationLog.start_link(id: "l", dir: dir, name: name)
    %{dir: dir, name: name}
  end

  test "checkpoint survives restart with exact packet", %{dir: dir, name: name} do
    :ok = OperationLog.record_intent(name, "op", "tool", nil)
    :ok = OperationLog.record_attempt(name, "op", "attempt")
    packet = %{"state" => %{"step" => 2}, "budget" => 7, "items" => ["a", "b"]}
    assert :ok = OperationLog.record_checkpoint(name, "op", "attempt", packet)
    assert {:checkpointed, ^packet, "attempt"} = OperationLog.status(name, "op")
    {:ok, view} = OperationLog.recovery(name, "op")
    assert view.checkpoint == packet
    assert view.checkpoint_decision == nil
    GenServer.stop(name)

    name2 =
      String.to_atom(
        "checkpoint_restart_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    {:ok, _} = OperationLog.start_link(id: "l", dir: dir, name: name2)
    assert {:checkpointed, ^packet, "attempt"} = OperationLog.status(name2, "op")
  end

  test "fences stale attempt and revision and accepts one resume", %{name: name} do
    :ok = OperationLog.record_intent(name, "op", "tool", nil)
    :ok = OperationLog.record_attempt(name, "op", "attempt")
    packet = %{"state" => "x"}
    assert {:error, :stale_attempt} = OperationLog.record_checkpoint(name, "op", "other", packet)
    assert :ok = OperationLog.record_checkpoint(name, "op", "attempt", packet)
    assert {:error, :checkpoint_active} = OperationLog.record_attempt(name, "op", "attempt")
    assert {:error, :checkpoint_active} = OperationLog.record_release(name, "op", "attempt")

    assert {:error, :checkpoint_active} =
             OperationLog.record_outcome(name, "op", "attempt", :completed, %{})

    assert {:error, :stale_revision} =
             OperationLog.resume_checkpoint(name, "op", 1, %{"decision" => "approve"})

    assert {:ok, view} = OperationLog.resume_checkpoint(name, "op", 3, %{"decision" => "approve"})
    assert view.checkpoint_decision == %{"decision" => "approve"}

    assert {:error, :stale_revision} =
             OperationLog.resume_checkpoint(name, "op", 3, %{"decision" => "deny"})
  end

  test "retains packet and decision after a new dispatch", %{name: name} do
    :ok = OperationLog.record_intent(name, "op", "tool", nil)
    :ok = OperationLog.record_attempt(name, "op", "first")
    :ok = OperationLog.record_checkpoint(name, "op", "first", %{"state" => 1})
    {:ok, _} = OperationLog.resume_checkpoint(name, "op", 3, %{"decision" => "approve"})
    :ok = OperationLog.record_attempt(name, "op", "second")
    {:ok, view} = OperationLog.recovery(name, "op")
    assert view.checkpoint == %{"state" => 1}
    assert view.checkpoint_decision == %{"decision" => "approve"}
    assert view.checkpoint_grant_revision == 4
    assert view.revision == view.checkpoint_grant_revision + 1
    assert view.checkpointed_attempts == ["first"]
    assert {:dispatched, "second"} = OperationLog.status(name, "op")
  end

  test "checkpointed entries are not evicted", %{dir: dir} do
    name =
      String.to_atom("checkpoint_bound_" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, _} = OperationLog.start_link(id: "bound", dir: dir, name: name, max_ops: 1)
    :ok = OperationLog.record_intent(name, "op", "tool", nil)
    :ok = OperationLog.record_attempt(name, "op", "attempt")
    :ok = OperationLog.record_checkpoint(name, "op", "attempt", %{"state" => 1})
    assert {:error, :ledger_full} = OperationLog.record_intent(name, "other", "tool", nil)
  end
end
