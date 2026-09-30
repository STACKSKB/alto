defmodule Alto.Contrib.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Alto.Contrib.External.Registry},
      {DynamicSupervisor,
       name: Alto.Contrib.External.Supervisor,
       strategy: :one_for_one,
       max_children: Application.get_env(:alto_contrib, :max_external_clients, 64)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Alto.Contrib.Supervisor)
  end
end
