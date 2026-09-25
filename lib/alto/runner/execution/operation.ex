defmodule Alto.Runner.Execution.Operation do
  @moduledoc "Allocate a unique operation ID within one run."

  def next(%{op_seq: seq, tool_context: %{session_id: run_id}} = run) do
    next_seq = seq + 1
    {"#{run_id}:op-#{next_seq}", %{run | op_seq: next_seq}}
  end
end
