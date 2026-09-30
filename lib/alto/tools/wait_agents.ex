defmodule Alto.Tools.WaitAgents do
  @moduledoc "Join owned children or yield until steering arrives, without occupying a child slot."
  use Alto.Tool,
    name: :wait_agents,
    runtime_operation: :wait_agents,
    execution_mode: :exclusive,
    approval: :never,
    arguments: true

  alias Alto.Tool.Arguments
  @impl true
  def arguments(_opts) do
    {"Wait for any selected child to finish, an incoming steering message, or timeout. Supply child agent_id values returned by start_agents; an empty list waits only for a message. Already completed agents return immediately; omit them when waiting for others. Results retain input order.",
     [
       agents: [type: Arguments.list(Arguments.text(1, 256), 0, 64), required: true],
       timeout_ms: [type: {:in, 0..60_000}, default: 30_000]
     ]}
  end

  @impl true
  def prepare(%{"agents" => ids, "timeout_ms" => timeout}, _, _) do
    if Enum.uniq(ids) == ids,
      do: {:ok, %{agents: ids, timeout_ms: timeout}, %{}},
      else: {:error, :invalid_wait}
  end

  @impl true
  def run(_, _, _), do: {:error, :delegation_requires_execution_host}
end
