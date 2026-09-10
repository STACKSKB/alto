defmodule Alto.OperationLogKeysTest do
  use ExUnit.Case, async: true

  alias Alto.OperationLog

  defp start!(opts) do
    name = :"keys_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      OperationLog.start_link(
        Keyword.merge(
          [id: "l#{System.unique_integer([:positive])}", dir: opts[:dir], name: name],
          opts
        )
      )

    name
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-keys-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "includes released entries in insertion order", %{dir: dir} do
    ledger = start!(dir: dir)
    :ok = OperationLog.record_intent(ledger, "op-1", "tool", nil)
    :ok = OperationLog.record_attempt(ledger, "op-1", "attempt-1")
    :ok = OperationLog.record_release(ledger, "op-1", "attempt-1")
    :ok = OperationLog.record_intent(ledger, "op-2", "tool", nil)

    assert ["op-1", "op-2"] = OperationLog.keys(ledger)
  end

  test "is bounded by retained max_ops after terminal eviction", %{dir: dir} do
    ledger = start!(dir: dir, max_ops: 2)

    for n <- 1..2 do
      key = "op-#{n}"
      attempt = "attempt-#{n}"
      :ok = OperationLog.record_intent(ledger, key, "tool", nil)
      :ok = OperationLog.record_attempt(ledger, key, attempt)
      :ok = OperationLog.record_outcome(ledger, key, attempt, :completed, %{})
    end

    :ok = OperationLog.record_intent(ledger, "op-3", "tool", nil)
    assert ["op-2", "op-3"] = OperationLog.keys(ledger)
  end
end
