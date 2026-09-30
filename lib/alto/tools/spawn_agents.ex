defmodule Alto.Tools.SpawnAgents do
  @moduledoc "Create agents with a selected backend and model; the host owns the child batch."
  use Alto.Tool,
    name: :spawn_agents,
    runtime_operation: :spawn_agents,
    execution_mode: :exclusive,
    approval: :required,
    arguments: true

  alias Alto.Tool.Arguments

  @impl true
  def arguments(opts) do
    Alto.Subagents.Models.validate_policy!(Keyword.get(opts, :models, :all))

    {"Create agents using backend and model IDs from list_agent_models, and wait for their results. Give each agent a self-contained task; it does not receive this conversation. Codex agents are read-only and externally metered.",
     [
       agents: [
         type:
           Arguments.list(
             Arguments.object(
               id: [type: Arguments.text(1, 256), required: true],
               backend: [type: Arguments.text(1, 256), required: true],
               model: [type: Arguments.text(1, 256), required: true],
               task: [type: Arguments.text(1, 64_000), required: true]
             ),
             1,
             min(64, Keyword.get(opts, :max_children, 64))
           ),
         required: true
       ]
     ]}
  end

  @impl true
  def prepare(%{"agents" => requests}, _context, _opts) do
    agents =
      Enum.map(requests, fn request ->
        %{
          id: request["id"],
          profile_key: request["backend"],
          model: request["model"],
          task: request["task"]
        }
      end)

    {:ok, %{agents: agents}, %{}}
  end

  @impl true
  def run(_, _, _), do: {:error, :delegation_requires_execution_host}
end
