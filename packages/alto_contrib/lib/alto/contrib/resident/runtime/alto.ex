defmodule Alto.Contrib.Resident.Runtime.Alto do
  @moduledoc "Composes Alto's resident registry and Unix socket transport."
  @behaviour Alto.Contrib.Resident.Runtime

  @impl true
  def children(config, name) do
    registry = Alto.Contrib.Resident.Service.component(name, :runtime)

    {stores, workers} = Alto.Contrib.Resident.Tasks.children(config, name)

    stores ++
      Alto.Contrib.Resident.ParentRuns.children(config, name) ++
      [
        Alto.Contrib.Resident.Lifecycle.child(config, name),
        Alto.Contrib.Resident.Mailbox.child(config, name),
        Alto.Contrib.Resident.Workspaces.child(config, name)
      ] ++
      [
        {Alto.Contrib.FrontEnd.Registry,
         name: registry,
         config_resolver: &Alto.Contrib.Resident.Tasks.resolve(config, &1),
         commands:
           Alto.Contrib.Resident.Tasks.commands(name)
           |> Map.merge(Alto.Contrib.Resident.Mailbox.commands(name))
           |> Map.merge(Alto.Contrib.Resident.ChildRuns.commands(name))
           |> Map.merge(Alto.Contrib.Resident.Workspaces.commands(config, name))
           |> Map.merge(Alto.Contrib.Resident.Projects.commands(config)),
         max_active_runs: config.scheduling[:workers] + 2,
         cwd: config.workspace,
         sessions: [session_dir: Path.join(config.state_dir, "sessions")],
         max_retained_events: config.max_retained_events}
      ] ++
      workers ++
      [
        {Alto.Contrib.Listeners.UnixSocket,
         name: Alto.Contrib.Resident.Service.component(name, :socket),
         registry: registry,
         path: Alto.Contrib.Resident.Config.socket_path(config)}
      ]
  end
end
