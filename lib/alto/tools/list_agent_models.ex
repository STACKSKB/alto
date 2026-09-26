defmodule Alto.Tools.ListAgentModels do
  @moduledoc "Discover models available for creating agents, without exposing credentials."
  use Alto.Tool,
    name: :list_agent_models,
    execution_mode: :exclusive,
    approval: :never,
    arguments: true

  @impl true
  def arguments(opts) do
    Alto.Subagents.Models.validate_policy!(Keyword.get(opts, :models, :all))

    {"List available agent backends and models. Results are paginated; use backend or query to narrow the search.",
     [
       backend: [type: :string],
       query: [type: :string],
       offset: [type: :non_neg_integer, default: 0],
       limit: [type: {:in, 1..100}, default: 50]
     ]}
  end

  @impl true
  def run(_, _, _), do: {:error, :model_discovery_requires_execution_host}
end
