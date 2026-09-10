defmodule Alto.QueueCancelPendingTest do
  use ExUnit.Case, async: true

  alias Alto.Queue

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-cancel-pending-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    name = :"cancel_pending_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Queue.start_link(id: "q", dir: dir, name: name)
    %{dir: dir, name: name}
  end

  test "claimed key is preserved, then can be cancelled after release", %{name: name} do
    {:ok, _} = Queue.put(name, "job", %{value: 1})
    {:ok, [claimed]} = Queue.claim(name)

    assert {:error, {:key_claimed, "job"}} = Queue.cancel_pending(name, "job")
    assert {:ok, %{status: :claimed, claim_id: claim_id}} = Queue.lookup(name, "job")
    assert claim_id == claimed.claim_id

    assert :ok = Queue.release(name, claim_id)
    assert :ok = Queue.cancel_pending(name, "job")
    assert {:error, :not_found} = Queue.lookup(name, "job")
  end

  test "cancelled pending record stays absent after restart", %{dir: dir, name: name} do
    {:ok, _} = Queue.put(name, "job", %{value: 1})
    assert :ok = Queue.cancel_pending(name, "job")
    GenServer.stop(name)

    name2 = :"cancel_pending_restart_#{System.unique_integer([:positive])}"
    {:ok, _} = Queue.start_link(id: "q", dir: dir, name: name2)
    assert {:error, :not_found} = Queue.lookup(name2, "job")
    assert {:ok, []} = Queue.claim(name2)
  end

  test "missing key is reported", %{name: name} do
    assert {:error, :not_found} = Queue.cancel_pending(name, "missing")
  end
end
