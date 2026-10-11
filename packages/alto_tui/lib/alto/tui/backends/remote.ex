defmodule Alto.TUI.Backends.Remote do
  @moduledoc """
  Resident service backend using Alto's shared navigation, transcript and decisions.
  Configuration chooses a trusted server profile, socket or managed SSH tunnel.
  Closing the terminal releases the connection; it never cancels server work.
  """
  @behaviour Alto.TUI.Backend
  alias Alto.Contrib.Resident.Connection
  alias Alto.TUI.{Menu, State}

  @impl true
  def ui(:init, state, options) do
    put_data(state, %{
      options: Keyword.delete(options, :label),
      connection: nil,
      model: nil,
      busy: false,
      local: nil
    })
  end

  def ui(event, state, _options) when event in [:prepare, :selected] do
    state =
      if data(state).local == nil do
        local =
          Map.take(state, [
            :projects,
            :tasks,
            :selected_project_id,
            :selected_task_id,
            :selected_provider_id
          ])

        put_data(state, %{data(state) | local: local})
      else
        state
      end

    state = ensure_connection(state)
    if data(state).model, do: project(state, data(state).model), else: state
  end

  def ui(:leaving, state, _) do
    case data(state).local do
      nil ->
        state

      local ->
        local =
          case Alto.TUI.Catalog.navigation(state.catalog_opts) do
            {:ok, projects, tasks} -> Map.merge(local, %{projects: projects, tasks: tasks})
            _ -> local
          end

        next = state |> put_data(%{data(state) | local: nil}) |> Map.merge(local)
        %{next | selected_task_id: nil}
    end
  end

  def ui(:provider_label, state, _), do: "Resident · " <> connection_label(state)
  def ui(:activity, state, _), do: selected_status(state)

  def ui(:models, state, _) do
    case data(state).model do
      %{effort_catalog: %{"model" => model, "efforts" => choices}} ->
        [%{id: model, efforts: choices}]

      _ ->
        []
    end
  end

  def ui(:sync_model, _, _), do: nil
  def ui(:steering?, _, _), do: false
  def ui(:session_usage?, _, _), do: false

  def ui(:details, state, _),
    do: {" Service task ", (data(state).model && data(state).model.detail) || "Connecting…"}

  def ui({:message, {:alto_resident_snapshot, pid, action, model}}, state, _) do
    if data(state).connection == pid do
      busy = data(state).busy and action in [:poll, :connect]
      next = put_data(state, %{data(state) | model: model, busy: busy})
      next = if selected?(state), do: project(next, model), else: next

      if match?({:submit, _}, action) and model.notice in ["Sent", ""] do
        ExRatatui.textarea_set_value(state.textarea, "")
      end

      next =
        if action == :efforts and model.effort_catalog and selected?(state) do
          items = [
            %{label: "Provider default", value: {:remote_effort, nil}}
            | Enum.map(
                model.effort_catalog["efforts"],
                &%{label: &1, value: {:remote_effort, &1}}
              )
          ]

          %{
            next
            | overlay:
                Menu.new(
                  :effort,
                  "Service model effort",
                  items,
                  {:remote_effort, model.selected_effort}
                ),
              selected_model: model.effort_catalog["model"]
          }
        else
          next
        end

      {:noreply, next}
    else
      :pass
    end
  end

  def ui(
        {:message, {:alto_resident_complete, path}},
        %{overlay: %{kind: :workspace_form} = form} = state,
        _
      ) do
    if data(state).connection && Menu.value(form, :path) == path,
      do: GenServer.cast(data(state).connection, {:complete, path})

    {:noreply, state, render?: false}
  end

  def ui(
        {:message, {:alto_resident_folders, pid, path, reply}},
        %{overlay: %{kind: :workspace_form} = form} = state,
        _
      ) do
    if data(state).connection == pid and Menu.value(form, :path) == path do
      form =
        case reply do
          {:ok, result} ->
            Map.merge(form, %{
              suggestions: result.folders,
              completion: result.completion,
              suggestion_index: nil,
              completion_pending?: false,
              error: nil
            })

          {:error, reason} ->
            Map.merge(form, %{
              suggestions: [],
              completion: nil,
              completion_pending?: false,
              error: Alto.Contrib.Display.error(reason)
            })
        end

      form =
        if form[:tab_pending?] and is_binary(form[:completion]),
          do: Menu.complete_folder(form, form.completion),
          else: form

      {:noreply, %{state | overlay: form, leader?: false}}
    else
      {:noreply, state, render?: false}
    end
  end

  def ui({:message, _}, _, _), do: :pass
  def ui(:workspace_form, state, _), do: workspace_form(state)

  def ui(
        {:overlay_key, %ExRatatui.Event.Key{code: "n", modifiers: ["ctrl"]}},
        %{overlay: %{kind: :workspace_form} = form} = state,
        _
      ),
      do: action(state, {:create_workspace, Menu.value(form, :path)})

  def ui(
        {:overlay_key, %ExRatatui.Event.Key{code: "o", modifiers: ["ctrl"]}},
        %{overlay: %{kind: :workspace_form}} = state,
        _
      ),
      do: state

  def ui({:submit, %Alto.Content{}}, state, _),
    do: %{state | notice: "Remote attachments require a server-accessible file; draft kept"}

  def ui({:submit, prompt}, state, _), do: action(state, {:submit, prompt})
  def ui({:cancel, _}, state, _), do: action(state, :cancel)
  def ui({:decide, _}, %{pending_approvals: [_ | _]}, _), do: :pass
  def ui({:decide, :approve}, state, _), do: action(state, :approve)
  def ui({:decide, _}, state, _), do: action(state, :deny)
  def ui(:new_task, state, _), do: action(state, :new)
  def ui({:select_task, id}, state, _), do: action(state, {:select, id})
  def ui({:select_project, id}, state, _), do: action(state, {:select_workspace, id})
  def ui({:close_workspace, id}, state, _), do: action(state, {:close_workspace, id})
  def ui({:open_workspace, path}, state, _), do: action(state, {:workspace, path})

  def ui({:overlay, :project}, state, _) do
    items =
      Enum.map(
        State.open_projects(state),
        &%{label: &1["name"], value: {:remote_project, &1["id"]}}
      )

    items =
      items ++
        [
          %{label: "Open folder on server…", action: &workspace_form/1},
          %{
            label: "Close selected workspace",
            action: &action(&1, {:close_workspace, &1.selected_project_id})
          }
        ]

    {:ok, "Service workspaces", items, {:remote_project, state.selected_project_id}}
  end

  def ui({:overlay, :approval}, _state, _) do
    {:ok, "Service decisions",
     [
       %{label: "Approve exact pending action", action: &action(&1, :approve)},
       %{label: "Deny exact pending action", action: &action(&1, :deny)},
       %{label: "Recover retained parent continuation", action: &recover/1},
       %{label: "Decide a suspended child…", action: &child_form/1},
       %{label: "Reconcile uncertain outcome…", action: &reconcile_form/1},
       %{label: "Retire terminal task resources", action: &cleanup/1}
     ], nil}
  end

  def ui({:overlay, kind}, state, _) when kind in [:provider, :model],
    do:
      {:state,
       %{state | notice: "Profile and authority are selected by the service configuration"}}

  def ui({:overlay, :effort}, state, _), do: {:state, action(state, :efforts)}
  def ui({:select, {:remote_effort, value}}, state, _), do: action(state, {:effort, value})

  def ui({:select, {:remote_project, id}}, state, _), do: action(state, {:select_workspace, id})
  def ui(_, _, _), do: :pass

  @impl true
  def cancel(_run, _reason, _options), do: :ok

  defp ensure_connection(state) do
    case data(state).connection do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: state, else: connect(state)

      _ ->
        connect(state)
    end
  end

  defp connect(state) do
    {:ok, pid} = Connection.start(self(), data(state).options)
    put_data(state, %{data(state) | connection: pid})
  end

  defp action(state, action) do
    state = ensure_connection(state)

    if data(state).busy do
      %{state | notice: "A service command is pending; draft kept"}
    else
      Connection.action(data(state).connection, action)
      state = put_data(state, %{data(state) | busy: true})
      %{state | overlay: nil, leader?: false, notice: "Waiting for service…"}
    end
  end

  defp workspace_form(state) do
    state = ensure_connection(state)
    owner = self()

    complete = fn path ->
      Process.send_after(owner, {:alto_resident_complete, path}, 100)
      :pending
    end

    form =
      Menu.form(:workspace_form, "Folder on service host", [{:path, "Path", "", []}],
        base: (data(state).model && data(state).model.workspace_base) || "/",
        complete: complete,
        folders: Enum.map(state.projects, &(&1["root"] <> "/")),
        buttons: ["Open", "Create", "Cancel"],
        actions: [:submit, :create, :cancel],
        on_action: fn s, event ->
          case event do
            :cancel -> %{s | overlay: nil}
            :create -> action(s, {:create_workspace, Menu.value(s.overlay, :path)})
            :submit -> action(s, {:workspace, Menu.value(s.overlay, :path)})
          end
        end
      )

    %{state | overlay: form, leader?: false}
  end

  defp reconcile_form(state) do
    form =
      Menu.form(
        :remote_reconcile,
        "Review uncertain effects",
        [{:note, "Evidence / reason", "", []}],
        buttons: ["Committed", "Failed", "Permit retry", "Cancel"],
        actions: [:committed, :failed, :retry, :cancel],
        on_action: fn s, event ->
          if event == :cancel,
            do: %{s | overlay: nil},
            else: action(s, {:reconcile, Atom.to_string(event), Menu.value(s.overlay, :note)})
        end
      )

    %{state | overlay: form, leader?: false}
  end

  defp selected_task(state) do
    model = data(state).model
    model && Enum.find(model.tasks, &(&1.id == model.selected_id))
  end

  defp cleanup(state) do
    case selected_task(state) do
      %{durable: true, id: id, revision: revision} ->
        action(state, {:command, "tasks.cleanup", %{id: id, revision: revision}})

      _ ->
        %{state | overlay: nil, notice: "Select a durable terminal task"}
    end
  end

  defp recover(state) do
    action(state, :recover)
  end

  defp child_form(state) do
    form =
      Menu.form(
        :remote_child,
        "Exact suspended child decision",
        [
          {:child, "Child ID", "", []},
          {:key, "Batch key", "", []},
          {:generation, "Batch generation", "", []},
          {:batch_revision, "Batch revision", "", []},
          {:attempt, "Attempt", "", []},
          {:suspension, "Suspension nonce", "", []}
        ],
        buttons: ["Approve", "Deny", "Cancel"],
        actions: [:approve, :deny, :cancel],
        on_action: fn s, event ->
          task = selected_task(s)

          if event == :cancel or task == nil do
            %{s | overlay: nil}
          else
            fields = Menu.values(s.overlay)

            with {revision, ""} <- Integer.parse(fields.batch_revision) do
              payload =
                Map.merge(fields, %{
                  id: task.id,
                  revision: task.revision,
                  batch_revision: revision,
                  decision: Atom.to_string(event)
                })

              action(s, {:command, "tasks.child_decide", payload})
            else
              _ -> %{s | notice: "Batch revision must be an integer"}
            end
          end
        end
      )

    %{state | overlay: form, leader?: false}
  end

  defp project(state, model) do
    backend = state.selected_backend |> Atom.to_string()

    tasks =
      Enum.map(model.tasks, fn task ->
        %{
          "id" => task.id,
          "project_id" => task.workspace_id || model.workspace_id,
          "title" => task.title,
          "status" => task.status,
          "backend" => backend,
          "conversation_id" => task.session_id
        }
      end)
      |> Enum.group_by(& &1["project_id"])

    task = Enum.find(model.tasks, &(&1.id == model.selected_id))
    workspace = (task && task.workspace_id) || model.workspace_id

    state = %{
      state
      | projects: model.projects,
        tasks: tasks,
        selected_project_id: workspace,
        selected_task_id: model.selected_id,
        notice: model.notice
    }

    state = State.put_entries(state, model.selected_id, model.entries)
    task = selected_task(state)
    if task, do: State.put_usage(state, task.id, Alto.Usage.normalize(task.usage)), else: state
  end

  defp connection_label(state),
    do: (data(state).model && data(state).model.connection) || "connecting"

  defp selected_status(state) do
    case selected_task(state) do
      nil -> connection_label(state)
      task -> task.status
    end
  end

  defp selected?(state),
    do:
      match?(
        {:ok, __MODULE__, _},
        Alto.TUI.Backend.lookup(state.run_options, state.selected_backend)
      )

  defp data(state), do: Map.fetch!(state.backend_state, __MODULE__)

  defp put_data(state, data),
    do: %{state | backend_state: Map.put(state.backend_state, __MODULE__, data)}
end
