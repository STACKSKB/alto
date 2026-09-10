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
    :ok = OperationLog.record_intent(name, "op", "tool", nil)
    assert :ok = OperationLog.reject_intended(name, "op", 1, %{status: "cancelled"})

    assert {:decided, :rejected_before_dispatch, %{status: "cancelled"}} =
             OperationLog.status(name, "op")

    GenServer.stop(name)

    name2 =
      String.to_atom("reject_restart_" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, _} = OperationLog.start_link(id: "l", dir: dir, name: name2)
    assert {:decided, :rejected_before_dispatch, _} = OperationLog.status(name2, "op")
  end

  test "fences stale revisions and active attempts", %{name: name} do
    :ok = OperationLog.record_intent(name, "op", "tool", nil)
    assert {:error, :stale_revision} = OperationLog.reject_intended(name, "op", 2, %{})
    :ok = OperationLog.record_attempt(name, "op", "live")
    assert {:error, :attempt_in_flight} = OperationLog.reject_intended(name, "op", 2, %{})
  end

  test "released retry can be rejected", %{name: name} do
    :ok = OperationLog.record_intent(name, "op", "tool", nil)
    :ok = OperationLog.record_attempt(name, "op", "try")
    :ok = OperationLog.record_release(name, "op", "try")
    assert :ok = OperationLog.reject_intended(name, "op", 3, %{})
    assert {:decided, :rejected_before_dispatch, _} = OperationLog.status(name, "op")
  end

  test "a partial reject tail does not create an attempt", %{dir: dir, name: name} do
    :ok = OperationLog.record_intent(name, "op", "tool", nil)
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
    assert {:intended} = OperationLog.status(name2, "op")
    assert {:ok, _} = OperationLog.recovery(name2, "op")
  end

  test "decided rejection cannot be overwritten", %{name: name} do
    :ok = OperationLog.record_intent(name, "op", "tool", nil)
    :ok = OperationLog.reject_intended(name, "op", 1, %{})

    assert OperationLog.reject_intended(name, "op", 1, %{}) in [
             {:error, :already_decided},
             {:error, :stale_revision}
           ]
  end

  test "full attempt history is rejected without poisoning the log", %{dir: dir} do
    name = String.to_atom("reject_full_" <> Integer.to_string(System.unique_integer([:positive])))
    {:ok, _} = OperationLog.start_link(id: "full", dir: dir, name: name, max_attempts: 1)
    :ok = OperationLog.record_intent(name, "op", "tool", nil)
    :ok = OperationLog.record_attempt(name, "op", "try")
    :ok = OperationLog.record_release(name, "op", "try")
    path = Path.join(dir, "full.jsonl")
    before = File.read!(path)
    assert {:error, :attempt_history_full} = OperationLog.reject_intended(name, "op", 3, %{})
    assert File.read!(path) == before
    GenServer.stop(name)

    name2 =
      String.to_atom(
        "reject_full_restart_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    {:ok, _} = OperationLog.start_link(id: "full", dir: dir, name: name2, max_attempts: 1)
    assert {:intended} = OperationLog.status(name2, "op")
  end
end
