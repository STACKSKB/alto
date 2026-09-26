defmodule Alto.Tools.StartAgents do
  @moduledoc "Start owned children and return addresses before they finish."
  use Alto.Tool, name: :start_agents, execution_mode: :exclusive, approval: :required

  @impl true
  def schema(opts) do
    Alto.Tools.SpawnAgents.schema(opts)
    |> Map.put(
      :description,
      "Start agents and return agent_id addresses immediately. Use send_message to communicate and wait_agents to join. Children remain owned by this run and are cancelled when it ends. Live agents cannot be checkpointed."
    )
  end

  @impl true
  defdelegate prepare(arguments, context, opts), to: Alto.Tools.SpawnAgents
  @impl true
  def run(_, _, _), do: {:error, :delegation_requires_execution_host}
end
