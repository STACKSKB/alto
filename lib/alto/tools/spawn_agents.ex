defmodule Alto.Tools.SpawnAgents do
  @moduledoc "Create agents with a selected backend and model; the host owns the child batch."
  use Alto.Tool, name: :spawn_agents, execution_mode: :exclusive, approval: :required

  @impl true
  def schema(opts) do
    Alto.Subagents.Models.validate_policy!(Keyword.get(opts, :models, :all))

    Alto.Tool.object_schema(
      "Create agents using backend and model IDs from list_agent_models, and wait for their results. Give each agent a self-contained task; it does not receive this conversation. Codex agents are read-only and externally metered.",
      %{
        agents: %{
          type: "array",
          minItems: 1,
          maxItems: Keyword.get(opts, :max_children, 64),
          items: %{
            type: "object",
            additionalProperties: false,
            required: ["id", "backend", "model", "task"],
            properties: %{
              id: %{type: "string"},
              backend: %{type: "string"},
              model: %{type: "string"},
              task: %{type: "string"}
            }
          }
        }
      },
      ["agents"]
    )
  end

  @impl true
  def prepare(%{"agents" => requests} = arguments, _context, _opts)
      when map_size(arguments) == 1 and is_list(requests) and length(requests) in 1..64 do
    with {:ok, agents} <- Alto.Result.traverse(requests, &request/1),
         do: {:ok, %{agents: agents}, %{}}
  end

  def prepare(_, _, _), do: {:error, :invalid_agents}

  defp request(%{"id" => id, "backend" => backend, "model" => model, "task" => task} = request)
       when map_size(request) == 4 and is_binary(id) and byte_size(id) in 1..256 and
              is_binary(backend) and byte_size(backend) in 1..256 and is_binary(model) and
              byte_size(model) in 1..256 and
              is_binary(task) and byte_size(task) in 1..64_000,
       do: {:ok, %{id: id, profile_key: backend, model: model, task: task}}

  defp request(_), do: {:error, :invalid_agent_request}

  @impl true
  def run(_, _, _), do: {:error, :delegation_requires_execution_host}
end
