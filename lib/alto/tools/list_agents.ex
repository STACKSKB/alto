defmodule Alto.Tools.ListAgents do
  @moduledoc "Discover agent addresses, parent relationships and status in this tree."
  use Alto.Tool,
    name: :list_agents,
    runtime_operation: :list_agents,
    execution_mode: :parallel,
    approval: :never,
    arguments: true

  @impl true
  def arguments(_opts) do
    {"List agents in this execution tree, including your own address and parent. Use agent_id for messaging; labels can repeat.",
     []}
  end

  @impl true
  def run(_args, context, _) do
    with {:ok, agents} <- Alto.Messaging.list(context[:messaging]), do: {:ok, %{agents: agents}}
  end
end
