defmodule Alto.Tools.WaitAgents do
  @moduledoc "Join owned children or yield until steering arrives, without occupying a child slot."
  use Alto.Tool, name: :wait_agents, execution_mode: :exclusive, approval: :never
  @impl true
  def schema(_) do
    Alto.Tool.object_schema(
      "Wait for any selected child to finish, an incoming steering message, or timeout. Supply child agent_id values returned by start_agents; an empty list waits only for a message. Already completed agents return immediately; omit them when waiting for others. Results retain input order.",
      %{
        agents: %{type: "array", maxItems: 64, items: %{type: "string"}},
        timeout_ms: %{type: "integer", minimum: 0, maximum: 60000}
      },
      ["agents"]
    )
  end

  @impl true
  def prepare(%{"agents" => ids} = args, _, _) when is_list(ids) and length(ids) <= 64 do
    timeout = Map.get(args, "timeout_ms", 30_000)

    if Map.keys(args) -- ["agents", "timeout_ms"] == [] and
         Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..256)) and
         length(Enum.uniq(ids)) == length(ids) and is_integer(timeout) and timeout in 0..60_000,
       do: {:ok, %{agents: ids, timeout_ms: timeout}, %{}},
       else: {:error, :invalid_wait}
  end

  def prepare(_, _, _), do: {:error, :invalid_wait}
  @impl true
  def run(_, _, _), do: {:error, :delegation_requires_execution_host}
end
