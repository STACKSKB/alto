defmodule Alto.Contrib.Tools.StartAgents do
  @moduledoc "Start owned children and return addresses before they finish."
  use Alto.Tool,
    name: :start_agents,
    runtime_operation: :start_agents,
    execution_mode: :exclusive,
    approval: :required

  @impl true
  def schema(opts) do
    Alto.Contrib.Tools.SpawnAgents.schema(opts)
    |> Map.put(
      :description,
      "Start agents and return pending agent_id addresses immediately; acceptance is not successful startup. Inspect wait_agents results for startup/provider failures. Use send_message to communicate and wait_agents to join. Children remain owned by this run and are cancelled when it ends. Pending messages and native agents are retained across supported checkpoints."
    )
  end

  @impl true
  defdelegate arguments(opts), to: Alto.Contrib.Tools.SpawnAgents

  @impl true
  defdelegate prepare(arguments, context, opts), to: Alto.Contrib.Tools.SpawnAgents
  @impl true
  def run(_, _, _), do: {:error, :delegation_requires_execution_host}
end
