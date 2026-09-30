defmodule Alto.Contrib.Tools do
  @moduledoc "Composable tool sets. Individual tool specifications remain usable directly."

  @agent_tools [
    list_agent_models: Alto.Contrib.Tools.ListAgentModels,
    spawn_agents: Alto.Contrib.Tools.SpawnAgents,
    start_agents: Alto.Contrib.Tools.StartAgents,
    wait_agents: Alto.Contrib.Tools.WaitAgents,
    send_message: Alto.Contrib.Tools.SendMessage,
    list_agents: Alto.Contrib.Tools.ListAgents
  ]

  @doc """
  Expose tools for discovering models and creating agents on demand.

      Alto.Contrib.Tools.agents()
      Alto.Contrib.Tools.agents(only: [:spawn_agents])
      Alto.Contrib.Tools.agents(models: %{"openrouter" => ["vendor/model-id"]})

  Providers come from the run's provider profiles (or its current provider).
  Registered whole-agent adapters supply their own models. By default every
  model can be selected; `:models` restricts backend IDs to explicit model IDs.
  Omitting `:only` includes this entire tool set, including future additions.
  """
  @spec agents(keyword()) :: [Alto.Tool.spec()]
  def agents(opts \\ []) do
    {only, opts} =
      Keyword.pop(Keyword.validate!(opts, [:only, :models]), :only, Keyword.keys(@agent_tools))

    Alto.Contrib.Subagents.Models.validate_policy!(Keyword.get(opts, :models, :all))
    Enum.map(only, &{Keyword.fetch!(@agent_tools, &1), opts})
  end
end
