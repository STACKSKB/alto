defmodule Alto.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Alto.TaskSupervisor},
      {Registry, keys: :unique, name: Alto.External.Registry},
      {DynamicSupervisor,
       name: Alto.External.Supervisor,
       strategy: :one_for_one,
       max_children: Application.get_env(:alto, :max_external_clients, 64)},
      # Optional runner lifecycle hosts own supervised execution tasks.
      {DynamicSupervisor, name: Alto.AgentSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Alto.Supervisor)
  end
end
