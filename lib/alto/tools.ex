defmodule Alto.Tools do
  @moduledoc "Composable tool sets. Individual tool specifications remain usable directly."

  @agent_tools [
    list_agent_models: Alto.Tools.ListAgentModels,
    spawn_agents: Alto.Tools.SpawnAgents,
    start_agents: Alto.Tools.StartAgents,
    wait_agents: Alto.Tools.WaitAgents,
    send_message: Alto.Tools.SendMessage,
    list_agents: Alto.Tools.ListAgents
  ]

  @doc """
  Expose tools for discovering models and creating agents on demand.

      Alto.Tools.agents()
      Alto.Tools.agents(only: [:spawn_agents])
      Alto.Tools.agents(models: %{"openrouter" => ["vendor/model-id"]})

  Providers come from the run's provider profiles (or its current provider).
  Registered whole-agent adapters supply their own models. By default every
  model can be selected; `:models` restricts backend IDs to explicit model IDs.
  Omitting `:only` includes this entire tool set, including future additions.
  """
  @spec agents(keyword()) :: [Alto.Tool.spec()]
  def agents(opts \\ []) do
    {only, opts} =
      Keyword.pop(Keyword.validate!(opts, [:only, :models]), :only, Keyword.keys(@agent_tools))

    Alto.Subagents.Models.validate_policy!(Keyword.get(opts, :models, :all))
    Enum.map(only, &{Keyword.fetch!(@agent_tools, &1), opts})
  end
end
