defmodule Alto.QueueRecoveryTest do
  use ExUnit.Case, async: true
  alias Alto.Queue

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto-queue-recovery-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    name =
      String.to_atom("queue_recovery_" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, _} = Queue.start_link(id: "q", dir: dir, name: name)
    %{name: name}
  end

  test "default restore remains idempotent", %{name: name} do
    assert {:ok, first} = Queue.request(name, {:restore, "op-1", "gen-1", %{value: 1}, []})

    assert {:error, :duplicate} =
             Queue.request(name, {:restore, "op-1", "gen-1", %{value: 1}, []})

    assert {:ok, [record]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
    assert record.id == first.id
    assert record.operation_key == "op-1"
  end

  test "same grant deduplicates after ack and later grant is distinct", %{name: name} do
    assert {:ok, first} =
             Queue.request(name, {:restore, "op-1", "gen-1", %{value: 1}, [recovery_revision: 4]})

    assert {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
    assert :ok = Queue.request(name, {:settle, claimed.claim_id, :ack, []})

    assert {:error, :duplicate} =
             Queue.request(name, {:restore, "op-1", "gen-1", %{value: 1}, [recovery_revision: 4]})

    assert {:ok, second} =
             Queue.request(name, {:restore, "op-1", "gen-1", %{value: 2}, [recovery_revision: 5]})

    assert second.id != first.id
    assert {:ok, [record]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
    assert record.operation_key == "op-1"
    assert record.generation_id == "gen-1"
    assert record.payload == %{value: 2}
  end

  test "revision must be positive", %{name: name} do
    assert {:error, {:invalid_recovery_revision, 0}} =
             Queue.request(name, {:restore, "op-1", "gen-1", %{}, [recovery_revision: 0]})
  end
end
