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
    :ok = OperationLog.record_intent(name, "bank", "budget", "mailbox")
    :ok = OperationLog.record_attempt(name, "bank", "attempt")
    :ok = OperationLog.record_checkpoint(name, "bank", "attempt", %{"used" => 1, "cap" => 4})
  end

  test "updates active checkpoint without changing attempt or grant", %{name: name} do
    checkpoint(name)
    packet = %{"used" => 2, "cap" => 4}
    assert {:ok, view} = OperationLog.update_checkpoint(name, "bank", 3, packet)
    assert view.checkpoint == packet
    assert view.revision == 4
    assert view.current_attempt == "attempt"
    assert view.checkpoint_grant_revision == nil
    assert view.checkpointed_attempts == ["attempt"]
    assert {:checkpointed, ^packet, "attempt"} = OperationLog.status(name, "bank")
  end

  test "competing updates are fenced by revision", %{name: name} do
    checkpoint(name)

    tasks =
      for value <- [2, 3] do
        Task.async(fn -> OperationLog.update_checkpoint(name, "bank", 3, %{"used" => value}) end)
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
             OperationLog.update_checkpoint(name, "bank", 3, %{"used" => 2})

    assert File.read!(state.path) == before
    assert {:ok, %{revision: 3}} = OperationLog.recovery(name, "bank")

    assert {:checkpointed, %{"used" => 1, "cap" => 4}, "attempt"} =
             OperationLog.status(name, "bank")
  end

  test "terminal outcome rejects checkpoint update", %{name: name} do
    checkpoint(name)
    assert {:ok, _} = OperationLog.resume_checkpoint(name, "bank", 3, %{"decision" => "deny"})
    assert :ok = OperationLog.record_attempt(name, "bank", "retry")
    assert :ok = OperationLog.record_outcome(name, "bank", "retry", :completed, %{})

    assert {:error, :already_decided} =
             OperationLog.update_checkpoint(name, "bank", 6, %{"used" => 2})
  end

  test "duplicate checkpoint update is rejected during replay", %{dir: dir, name: name} do
    checkpoint(name)
    GenServer.stop(name)
    path = Path.join(dir, "ledger.jsonl")

    line =
      JSON.encode!(%{
        "v" => 1,
        "t" => "checkpoint_update",
        "op" => "bank",
        "expected_revision" => 3,
        "checkpoint" => %{"used" => 2}
      })

    File.write!(path, line <> "\n" <> line <> "\n", [:append])

    assert {:error, :stale_revision} = OperationLog.start_link(id: "ledger", dir: dir, name: nil)
  end

  test "a torn update tail is discarded and prior update survives restart", %{
    dir: dir,
    name: name
  } do
    checkpoint(name)
    assert {:ok, _} = OperationLog.update_checkpoint(name, "bank", 3, %{"used" => 2})
    GenServer.stop(name)
    path = Path.join(dir, "ledger.jsonl")
    File.write!(path, ~s({"v":1,"t":"checkpoint_update"), [:append])

    {:ok, restarted} = OperationLog.start_link(id: "ledger", dir: dir, name: nil)
    assert {:checkpointed, %{"used" => 2}, "attempt"} = OperationLog.status(restarted, "bank")
  end

  test "update survives restart and cannot consume attempts", %{dir: dir, name: name} do
    checkpoint(name)
    assert {:ok, _} = OperationLog.update_checkpoint(name, "bank", 3, %{"used" => 2})

    assert {:error, :stale_revision} =
             OperationLog.update_checkpoint(name, "bank", 3, %{"used" => 3})

    GenServer.stop(name)
    {:ok, restarted} = OperationLog.start_link(id: "ledger", dir: dir, name: nil, max_attempts: 1)
    assert {:checkpointed, %{"used" => 2}, "attempt"} = OperationLog.status(restarted, "bank")
    assert 1 = OperationLog.attempts(restarted, "bank")

    assert {:ok, _} =
             OperationLog.resume_checkpoint(restarted, "bank", 4, %{"decision" => "continue"})

    assert {:error, :not_checkpointed} =
             OperationLog.update_checkpoint(restarted, "bank", 5, %{"used" => 3})
  end
end
