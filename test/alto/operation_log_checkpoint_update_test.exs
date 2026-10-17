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

  test "full log refusal leaves checkpoint and file unchanged", %{name: name} do
    checkpoint(name)
    state = :sys.get_state(name)
    before = File.read!(state.path)
    size = byte_size(before)
    :sys.replace_state(name, fn current -> %{current | max_log_bytes: size + 1} end)

    assert {:error, {:log_too_large, _, _}} =
             OperationLog.request(name, {:checkpoint_update, "bank", 3, %{"used" => 2}})

    assert File.read!(state.path) == before
    assert {:ok, %{revision: 3}} = OperationLog.request(name, {:recovery, "bank"})

    assert {:checkpointed, %{"used" => 1, "cap" => 4}, "attempt"} =
             OperationLog.request(name, {:status, "bank"})
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
end
