defmodule Alto.OperationLogCheckpointUpdateTest do
  use ExUnit.Case, async: false

  alias Alto.OperationLog

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-checkpoint-update-#{System.unique_integer([:positive])}")

    {:ok, pid} = OperationLog.start_link(id: "ledger", dir: dir, name: nil, max_attempts: 2)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: pid}
  end

  defp checkpoint(name) do
    :ok = OperationLog.request(name, {:intent, "bank", "budget", "mailbox", nil})
    :ok = OperationLog.request(name, {:attempt, "bank", "attempt"})
    :ok = OperationLog.request(name, {:checkpoint, "bank", "attempt", %{"used" => 1, "cap" => 4}})
  end

  test "updates active checkpoint without changing attempt or grant", %{name: name} do
    checkpoint(name)
    packet = %{"used" => 2, "cap" => 4}
    assert {:ok, view} = OperationLog.request(name, {:checkpoint_update, "bank", 3, packet})
    assert view.checkpoint == packet
    assert view.revision == 4
    assert view.current_attempt == "attempt"
    assert view.checkpoint_grant_revision == nil
    assert view.checkpointed_attempts == ["attempt"]
    assert {:checkpointed, ^packet, "attempt"} = OperationLog.request(name, {:status, "bank"})

    # A successful write consumes the revision even when the payload is unchanged.
    assert {:ok, %{revision: 5}} =
             OperationLog.request(name, {:checkpoint_update, "bank", 4, packet})

    assert {:error, :stale_revision} =
             OperationLog.request(name, {:checkpoint_update, "bank", 4, packet})
  end

  test "competing updates are fenced by revision", %{name: name} do
    checkpoint(name)

    tasks =
      for value <- [2, 3] do
        Task.async(fn ->
          OperationLog.request(name, {:checkpoint_update, "bank", 3, %{"used" => value}})
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 1_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_revision})) == 1
  end

  test "full log refusal leaves checkpoint and file unchanged", %{name: name} do
    checkpoint(name)
    state = :sys.get_state(name)
    before = File.read!(state.path)
    size = byte_size(before)
    :sys.replace_state(name, fn current -> %{current | max_log_bytes: size + 1} end)

    assert {:error, {:ledger_log_too_large, _, _}} =
             OperationLog.request(name, {:checkpoint_update, "bank", 3, %{"used" => 2}})

    assert File.read!(state.path) == before
    assert {:ok, %{revision: 3}} = OperationLog.request(name, {:recovery, "bank"})

    assert {:checkpointed, %{"used" => 1, "cap" => 4}, "attempt"} =
             OperationLog.request(name, {:status, "bank"})
  end

  test "terminal outcome rejects checkpoint update", %{name: name} do
    checkpoint(name)

    assert {:ok, _} =
             OperationLog.request(name, {:resume_checkpoint, "bank", 3, %{"decision" => "deny"}})

    assert :ok = OperationLog.request(name, {:attempt, "bank", "retry"})
    assert :ok = OperationLog.request(name, {:outcome, "bank", "retry", :completed, %{}})

    assert {:error, :not_checkpointed} =
             OperationLog.request(name, {:checkpoint_update, "bank", 6, %{"used" => 2}})
  end

  test "duplicate checkpoint update is rejected during replay", %{dir: dir, name: name} do
    checkpoint(name)
    GenServer.stop(name)
    path = Path.join(dir, "ledger.jsonl")

    {:ok, command} =
      Alto.Persistence.Codec.encode({:checkpoint_update, "bank", 3, %{"used" => 2}})

    line = JSON.encode!(command)

    File.write!(path, line <> "\n" <> line <> "\n", [:append])

    assert {:error, :stale_revision} = OperationLog.start_link(id: "ledger", dir: dir, name: nil)
  end

  test "a torn update tail is discarded and prior update survives restart", %{
    dir: dir,
    name: name
  } do
    checkpoint(name)
    assert {:ok, _} = OperationLog.request(name, {:checkpoint_update, "bank", 3, %{"used" => 2}})
    GenServer.stop(name)
    path = Path.join(dir, "ledger.jsonl")
    File.write!(path, ~s({"v":1,"t":"checkpoint_update"), [:append])

    {:ok, restarted} = OperationLog.start_link(id: "ledger", dir: dir, name: nil)

    assert {:checkpointed, %{"used" => 2}, "attempt"} =
             OperationLog.request(restarted, {:status, "bank"})
  end

  test "update survives restart and cannot consume attempts", %{dir: dir, name: name} do
    checkpoint(name)
    assert {:ok, _} = OperationLog.request(name, {:checkpoint_update, "bank", 3, %{"used" => 2}})

    assert {:error, :stale_revision} =
             OperationLog.request(name, {:checkpoint_update, "bank", 3, %{"used" => 3}})

    GenServer.stop(name)
    {:ok, restarted} = OperationLog.start_link(id: "ledger", dir: dir, name: nil, max_attempts: 1)

    assert {:checkpointed, %{"used" => 2}, "attempt"} =
             OperationLog.request(restarted, {:status, "bank"})

    assert 1 = OperationLog.request(restarted, {:attempts, "bank"})

    assert {:ok, _} =
             OperationLog.request(
               restarted,
               {:resume_checkpoint, "bank", 4, %{"decision" => "continue"}}
             )

    assert {:error, :not_checkpointed} =
             OperationLog.request(restarted, {:checkpoint_update, "bank", 5, %{"used" => 3}})
  end
end
