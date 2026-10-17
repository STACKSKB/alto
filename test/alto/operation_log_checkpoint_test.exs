defmodule Alto.OperationLogCheckpointTest do
  use ExUnit.Case, async: true
  alias Alto.OperationLog

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    name = String.to_atom("checkpoint_" <> Integer.to_string(System.unique_integer([:positive])))
    {:ok, _} = OperationLog.start_link(id: "l", dir: dir, name: name)
    %{dir: dir, name: name}
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
