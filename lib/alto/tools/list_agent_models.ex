defmodule Alto.Tools.ListAgentModels do
  @moduledoc "Discover models available for creating agents, without exposing credentials."
  use Alto.Tool, name: :list_agent_models, execution_mode: :exclusive, approval: :never

  @impl true
  def schema(opts) do
    Alto.Subagents.Models.validate_policy!(Keyword.get(opts, :models, :all))

    Alto.Tool.object_schema(
      "List available agent backends and models. Results are paginated; use backend or query to narrow the search.",
      %{
        backend: %{type: "string"},
        query: %{type: "string"},
        offset: %{type: "integer", minimum: 0},
        limit: %{type: "integer", minimum: 1, maximum: 100}
      },
      []
    )
  end

  @impl true
  def prepare(arguments, _context, _opts) when is_map(arguments) do
    if Map.keys(arguments) -- ~w(backend query offset limit) == [] and
         is_binary(Map.get(arguments, "backend", "")) and
         is_binary(Map.get(arguments, "query", "")) and
         is_integer(Map.get(arguments, "offset", 0)) and Map.get(arguments, "offset", 0) >= 0 and
         Map.get(arguments, "limit", 50) in 1..100 do
      {:ok, arguments, %{}}
    else
      {:error, :invalid_model_query}
    end
  end

  @impl true
  def run(_, _, _), do: {:error, :model_discovery_requires_execution_host}
end
