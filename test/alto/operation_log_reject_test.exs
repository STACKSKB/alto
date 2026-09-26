defmodule Alto.OperationLogRejectTest do
  use ExUnit.Case, async: true
  alias Alto.OperationLog

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto-reject-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    name = String.to_atom("reject_" <> Integer.to_string(System.unique_integer([:positive])))
    {:ok, _} = OperationLog.start_link(id: "l", dir: dir, name: name)
    %{dir: dir, name: name}
  end

  test "rejects intended and survives restart", %{dir: dir, name: name} do
    :ok = OperationLog.request(name, {:intent, "op", "tool", nil, nil})
    assert :ok = OperationLog.request(name, {:reject_intended, "op", 1, %{status: "cancelled"}})

    assert {:decided, :rejected_before_dispatch, %{status: "cancelled"}} =
             OperationLog.request(name, {:status, "op"})

    GenServer.stop(name)

    name2 =
      String.to_atom("reject_restart_" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, _} = OperationLog.start_link(id: "l", dir: dir, name: name2)
    assert {:decided, :rejected_before_dispatch, _} = OperationLog.request(name2, {:status, "op"})
  end

  test "fences stale revisions and active attempts", %{name: name} do
    :ok = OperationLog.request(name, {:intent, "op", "tool", nil, nil})

    assert {:error, :stale_revision} =
             OperationLog.request(name, {:reject_intended, "op", 2, %{}})

    :ok = OperationLog.request(name, {:attempt, "op", "live"})

    assert {:error, :invalid_operation_state} =
             OperationLog.request(name, {:reject_intended, "op", 2, %{}})
  end

  test "released retry can be rejected", %{name: name} do
    :ok = OperationLog.request(name, {:intent, "op", "tool", nil, nil})
    :ok = OperationLog.request(name, {:attempt, "op", "try"})
    :ok = OperationLog.request(name, {:release, "op", "try"})
    assert :ok = OperationLog.request(name, {:reject_intended, "op", 3, %{}})
    assert {:decided, :rejected_before_dispatch, _} = OperationLog.request(name, {:status, "op"})
  end

  test "a partial reject tail does not create an attempt", %{dir: dir, name: name} do
    :ok = OperationLog.request(name, {:intent, "op", "tool", nil, nil})
    GenServer.stop(name)
    path = Path.join(dir, "l.jsonl")

    File.write!(
      path,
      ~s({"v":1,"t":"reject","op":"op","expected_revision":1,"attempt":"rejected-x"),
      [:append]
    )

    name2 =
      String.to_atom("reject_partial_" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, _} = OperationLog.start_link(id: "l", dir: dir, name: name2)
    assert {:intended} = OperationLog.request(name2, {:status, "op"})
    assert {:ok, _} = OperationLog.request(name2, {:recovery, "op"})
  end

  test "decided rejection cannot be overwritten", %{name: name} do
    :ok = OperationLog.request(name, {:intent, "op", "tool", nil, nil})
    :ok = OperationLog.request(name, {:reject_intended, "op", 1, %{}})

    assert {:error, :invalid_operation_state} =
             OperationLog.request(name, {:reject_intended, "op", 2, %{}})
  end

  test "full attempt history is rejected without poisoning the log", %{dir: dir} do
    name = String.to_atom("reject_full_" <> Integer.to_string(System.unique_integer([:positive])))
    {:ok, _} = OperationLog.start_link(id: "full", dir: dir, name: name, max_attempts: 1)
    :ok = OperationLog.request(name, {:intent, "op", "tool", nil, nil})
    :ok = OperationLog.request(name, {:attempt, "op", "try"})
    :ok = OperationLog.request(name, {:release, "op", "try"})
    path = Path.join(dir, "full.jsonl")
    before = File.read!(path)

    assert {:error, :attempt_history_full} =
             OperationLog.request(name, {:reject_intended, "op", 3, %{}})

    assert File.read!(path) == before
    GenServer.stop(name)

    name2 =
      String.to_atom(
        "reject_full_restart_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    {:ok, _} = OperationLog.start_link(id: "full", dir: dir, name: name2, max_attempts: 1)
    assert {:intended} = OperationLog.request(name2, {:status, "op"})
  end
end
