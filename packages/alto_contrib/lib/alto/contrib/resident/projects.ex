defmodule Alto.Contrib.Resident.Projects do
  @moduledoc "Persistent folder workspaces selected by terminal clients on the service host."
  alias Alto.Contrib.Catalog

  def commands(config) do
    %{
      "projects.list" => fn _ ->
        with {:ok, default} <-
               Catalog.register_project(
                 config.workspace,
                 Keyword.put(opts(config), :reopen, false)
               ),
             {:ok, projects} <- Catalog.projects(opts(config)),
             do: {:ok, %{projects: projects, default: default}}
      end,
      "projects.complete" => fn
        %{"path" => path} ->
          Alto.Contrib.Folders.suggest(path, config.workspace)

        _ ->
          {:error, :invalid_workspace_path}
      end,
      "projects.session" => fn
        %{"session_id" => session} when is_binary(session) ->
          with {:ok, records} <-
                 Alto.Session.read(session,
                   session_dir: Path.join(config.state_dir, "sessions")
                 ) do
            root =
              Enum.find_value(records, fn record ->
                if record["type"] == "started" and record["session_owner"] != false,
                  do: record["cwd"]
              end)

            if is_binary(root) and root != "" do
              with {:ok, project} <- bind(config, root), do: {:ok, %{project: project}}
            else
              {:ok, %{project: nil}}
            end
          end

        _ ->
          {:error, :invalid_session}
      end,
      "projects.close" => fn
        %{"id" => id} when is_binary(id) ->
          with {:ok, project} <- Catalog.close_project(id, opts(config)),
               {:ok, projects} <- Catalog.projects(opts(config)),
               do: {:ok, %{project: project, projects: projects}}

        _ ->
          {:error, :invalid_workspace}
      end,
      "projects.create" => fn
        %{"path" => path} ->
          with {:ok, root} <- Alto.Contrib.Folders.create(path, config.workspace),
               do: open(config, root)

        _ ->
          {:error, :invalid_workspace_path}
      end,
      "projects.open" => fn
        %{"path" => path} -> open(config, path)
        _ -> {:error, :invalid_workspace_path}
      end
    }
  end

  def open(config, path) do
    with {:ok, project} <- Alto.Contrib.Folders.open(path, config.workspace, opts(config)),
         do: {:ok, %{project: project}}
  end

  def root(_config, nil, default), do: {:ok, default}

  def root(config, id, _default) when is_binary(id) do
    with {:ok, projects} <- Catalog.projects(opts(config)) do
      case Enum.find(projects, &(&1["id"] == id)) do
        nil ->
          {:error, :unknown_workspace}

        project ->
          if File.dir?(project["root"]),
            do: {:ok, project["root"]},
            else: {:error, :workspace_missing}
      end
    end
  end

  def root(_, _, _), do: {:error, :invalid_workspace}

  # A resumed conversation always stays in the folder recorded by its session.
  def resume_root(_config, nil, root, _explicit?), do: {:ok, root}

  def resume_root(config, session, root, explicit?) do
    with {:ok, records} <-
           Alto.Session.read(session, session_dir: Path.join(config.state_dir, "sessions")) do
      original =
        Enum.find_value(records, fn record ->
          if record["type"] == "started", do: record["cwd"]
        end) || root

      if explicit? and Path.expand(original) != Path.expand(root),
        do: {:error, :workspace_session_mismatch},
        else: {:ok, original}
    end
  end

  def bind(config, root),
    do: Catalog.register_project(root, Keyword.put(opts(config), :reopen, false))

  defp opts(config), do: [path: Path.join(config.state_dir, "projects.json")]
end
