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
    :ok = OperationLog.request(name, {:intent, "op", "tool", nil, nil})
    :ok = OperationLog.request(name, {:attempt, "op", "attempt"})
    packet = %{"state" => %{"step" => 2}, "budget" => 7, "items" => ["a", "b"], state: {:step, 3}}
    assert :ok = OperationLog.request(name, {:checkpoint, "op", "attempt", packet})
    assert {:checkpointed, ^packet, "attempt"} = OperationLog.request(name, {:status, "op"})
    {:ok, view} = OperationLog.request(name, {:recovery, "op"})
    assert view.checkpoint == packet
    assert view.checkpoint_decision == nil
    GenServer.stop(name)

    name2 =
      String.to_atom(
        "checkpoint_restart_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    {:ok, _} = OperationLog.start_link(id: "l", dir: dir, name: name2)
    assert {:checkpointed, ^packet, "attempt"} = OperationLog.request(name2, {:status, "op"})
  end

  test "fences stale attempt and revision and accepts one resume", %{name: name} do
    :ok = OperationLog.request(name, {:intent, "op", "tool", nil, nil})
    :ok = OperationLog.request(name, {:attempt, "op", "attempt"})
    packet = %{"state" => "x"}

    assert {:error, :stale_attempt} =
             OperationLog.request(name, {:checkpoint, "op", "other", packet})

    assert :ok = OperationLog.request(name, {:checkpoint, "op", "attempt", packet})
    assert {:error, :checkpoint_active} = OperationLog.request(name, {:attempt, "op", "attempt"})
    assert {:error, :checkpoint_active} = OperationLog.request(name, {:release, "op", "attempt"})

    assert {:error, :checkpoint_active} =
             OperationLog.request(name, {:outcome, "op", "attempt", :completed, %{}})

    assert {:error, :stale_revision} =
             OperationLog.request(name, {:resume_checkpoint, "op", 1, %{"decision" => "approve"}})

    assert {:ok, view} =
             OperationLog.request(name, {:resume_checkpoint, "op", 3, %{"decision" => "approve"}})

    assert view.checkpoint_decision == %{"decision" => "approve"}

    assert {:error, :stale_revision} =
             OperationLog.request(name, {:resume_checkpoint, "op", 3, %{"decision" => "deny"}})
  end

  test "retains packet and decision after a new dispatch", %{name: name} do
    :ok = OperationLog.request(name, {:intent, "op", "tool", nil, nil})
    :ok = OperationLog.request(name, {:attempt, "op", "first"})
    :ok = OperationLog.request(name, {:checkpoint, "op", "first", %{"state" => 1}})

    {:ok, _} =
      OperationLog.request(name, {:resume_checkpoint, "op", 3, %{"decision" => "approve"}})

    :ok = OperationLog.request(name, {:attempt, "op", "second"})
    {:ok, view} = OperationLog.request(name, {:recovery, "op"})
    assert view.checkpoint == %{"state" => 1}
    assert view.checkpoint_decision == %{"decision" => "approve"}
    assert view.checkpoint_grant_revision == 4
    assert view.revision == view.checkpoint_grant_revision + 1
    assert view.checkpointed_attempts == ["first"]
    assert {:dispatched, "second"} = OperationLog.request(name, {:status, "op"})
  end

  test "checkpointed entries are not evicted", %{dir: dir} do
    name =
      String.to_atom("checkpoint_bound_" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, _} = OperationLog.start_link(id: "bound", dir: dir, name: name, max_ops: 1)
    :ok = OperationLog.request(name, {:intent, "op", "tool", nil, nil})
    :ok = OperationLog.request(name, {:attempt, "op", "attempt"})
    :ok = OperationLog.request(name, {:checkpoint, "op", "attempt", %{"state" => 1}})

    assert {:error, :ledger_full} =
             OperationLog.request(name, {:intent, "other", "tool", nil, nil})
  end
end
