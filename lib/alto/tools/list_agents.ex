defmodule Alto.Tools.ListAgents do
  @moduledoc "Discover addresses, parent relationships and communication capabilities in this tree."
  use Alto.Tool, name: :list_agents, execution_mode: :parallel, approval: :never
  @impl true
  def schema(_),
    do:
      Alto.Tool.object_schema(
        "List agents in this execution tree, including your own address and parent. Use agent_id for messaging; labels can repeat. External backends may not support messaging.",
        %{},
        []
      )

  @impl true
  def run(args, context, _) when is_map(args) and map_size(args) == 0 do
    with {:ok, agents} <- Alto.Messaging.list(context.messaging), do: {:ok, %{agents: agents}}
  end

  def run(_, _, _), do: {:error, :invalid_arguments}
end
