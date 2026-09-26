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
    {:ok, _} = Queue.request(name, {:put, "job", %{value: 1}, []})
    {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})

    assert {:error, {:key_claimed, "job"}} = Queue.request(name, {:cancel_pending, "job"})
    assert {:ok, %{status: :claimed, claim_id: claim_id}} = Queue.request(name, {:lookup, "job"})
    assert claim_id == claimed.claim_id

    assert :ok = Queue.request(name, {:settle, claim_id, :release, []})
    assert :ok = Queue.request(name, {:cancel_pending, "job"})
    assert {:error, :not_found} = Queue.request(name, {:lookup, "job"})
  end

  test "cancelled pending record stays absent after restart", %{dir: dir, name: name} do
    {:ok, _} = Queue.request(name, {:put, "job", %{value: 1}, []})
    assert :ok = Queue.request(name, {:cancel_pending, "job"})
    GenServer.stop(name)

    name2 = :"cancel_pending_restart_#{System.unique_integer([:positive])}"
    {:ok, _} = Queue.start_link(id: "q", dir: dir, name: name2)
    assert {:error, :not_found} = Queue.request(name2, {:lookup, "job"})
    assert {:ok, []} = Queue.request(name2, {:claim, 1, nil, :infinity, :all})
  end

  test "missing key is reported", %{name: name} do
    assert {:error, :not_found} = Queue.request(name, {:cancel_pending, "missing"})
  end
end
