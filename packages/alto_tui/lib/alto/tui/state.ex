defmodule Alto.TUI.State do
  @moduledoc "State and catalog projection for the Alto terminal client."

  alias Alto.Harness.Catalog
  alias Alto.Harness.{ProviderProfile, ProviderStore}
  alias Alto.Session
  alias Alto.Usage

  @focuses [:rail, :transcript, :details, :composer]
  @max_entries_per_task 2_000
  @max_cached_tasks 12

  @enforce_keys [:textarea, :run_options, :catalog_opts]
  defstruct [
    :textarea,
    :run_options,
    :credentials_path,
    :selected_project_id,
    :selected_task_id,
    :selected_provider_id,
    :selected_model,
    :selected_backend,
    :overlay,
    :dragging,
    :notice,
    :clipboard_text,
    :clipboard_write,
    :clipboard_read,
    :drag_poll,
    activity_tick: 0,
    activity_started_ms: nil,
    selection: %Alto.TUI.Selection{},
    dimensions: {120, 36},
    projects: [],
    tasks: %{},
    entries: %{},
    profiles: [],
    models: %{},
    efforts: %{},
    model_loading: MapSet.new(),
    approval_level: :ask,
    composer_mode: :prose,
    type_to_compose?: true,
    narrow_context: :adaptive,
    narrow_context_width: 75,
    narrow_context_fullscreen_below: 72,
    approval_auto_open?: true,
    focus: :composer,
    leader?: false,
    details_visible?: true,
    details_drawer_open?: false,
    details_drawer_auto_opened?: false,
    details_return_focus: nil,
    rail_visible?: true,
    rail_width: 26,
    details_width: 36,
    transcript_scroll: 0,
    transcript_follow?: true,
    details_scroll: 0,
    pending_approvals: [],
    backend_state: %{},
    runs: %{},
    input_routes: %{},
    inputs: %{},
    usage: %{},
    catalog_opts: []
  ]

  @type t :: %__MODULE__{}

  @doc "Build TUI state and register the initial project root."
  @spec new(Alto.Config.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(%Alto.Config{} = config, opts \\ []) do
    run_options = Alto.Config.run_options(config)

    catalog_opts =
      opts
      |> Keyword.take([:path, :session_dir])
      |> Keyword.put_new_lazy(:session_dir, fn -> Keyword.get(run_options, :session_dir) end)
      |> Keyword.reject(fn {_key, value} -> is_nil(value) end)

    root = opts |> Keyword.get(:project, File.cwd!()) |> Path.expand()

    credentials_path = Keyword.get(opts, :credentials_path, Alto.Credentials.default_path())

    if not Alto.TUI.Backend.valid?(Alto.TUI.Backend.configured(run_options)),
      do: raise(ArgumentError, "invalid tui_backends")

    with {:ok, configured_profiles} <- ProviderProfile.from_run_options(run_options),
         {:ok, profiles} <-
           ProviderStore.profiles(configured_profiles, credentials_path: credentials_path),
         {:ok, selected_project} <- Catalog.register_project(root, catalog_opts),
         {:ok, projects} <- Catalog.projects(catalog_opts),
         {:ok, tasks} <- load_tasks(projects, catalog_opts) do
      selected_task = tasks |> Map.get(selected_project["id"], []) |> List.first()
      profile = List.first(profiles)
      tui_options = Keyword.get(run_options, :tui, [])

      selected_backend =
        if selected_task,
          do: task_backend(selected_task),
          else: List.first(Keyword.keys(Alto.TUI.Backend.configured(run_options)))

      state = %__MODULE__{
        textarea: ExRatatui.textarea_new(),
        clipboard_write:
          Keyword.get(
            opts,
            :clipboard_write,
            if(opts[:test_mode], do: fn _ -> :ok end, else: &Alto.TUI.Clipboard.write/1)
          ),
        clipboard_read: Keyword.get(opts, :clipboard_read, &Alto.TUI.Clipboard.read/0),
        run_options: run_options,
        credentials_path: credentials_path,
        catalog_opts: catalog_opts,
        projects: projects,
        tasks: tasks,
        selected_project_id: selected_project["id"],
        selected_task_id: selected_task && selected_task["id"],
        profiles: profiles,
        models: initial_models(profiles),
        selected_provider_id: profile && profile.id,
        type_to_compose?: Keyword.get(tui_options, :type_to_compose, true),
        narrow_context: Keyword.get(tui_options, :narrow_context, :adaptive),
        narrow_context_width: Keyword.get(tui_options, :narrow_context_width, 75),
        narrow_context_fullscreen_below:
          Keyword.get(tui_options, :narrow_context_fullscreen_below, 72),
        approval_auto_open?: Keyword.get(tui_options, :approval_auto_open, true),
        selected_model: profile && profile.default_model,
        selected_backend: selected_backend,
        usage: %{}
      }

      state = Alto.TUI.Backend.initialize(state)
      {:ok, hydrate_selected(state)}
    end
  end

  @doc "Visible execution stage and recovery controls for the selected task."
  def run_label(state) do
    queued? = input_pending?(state, state.selected_task_id)

    case Enum.find(state.runs, fn {_id, run} -> run.task_id == state.selected_task_id end) do
      nil ->
        if queued?, do: "message queued · Enter send", else: "idle"

      {id, run} ->
        phase =
          if Enum.any?(state.pending_approvals, &(Map.get(&1, :local_id) == id)),
            do: "waiting for approval",
            else: Map.get(run, :phase, "working")

        phase <>
          " · Esc stop" <>
          if(queued?, do: " · 1 queued", else: "")
    end
  end

  @doc "Whether a native task has accepted input waiting for delivery."
  def input_pending?(%__MODULE__{} = state, task_id) do
    case Map.get(state.inputs, task_id) do
      nil -> false
      input -> Alto.Input.list(input) != []
    end
  catch
    :exit, _ -> false
  end

  def model_metadata(state) do
    models =
      case Alto.TUI.Backend.ui(state, :models) do
        :pass -> Map.get(state.models, state.selected_provider_id, [])
        models -> models
      end

    Enum.find(models, fn model -> (model[:id] || model["id"]) == state.selected_model end)
  end

  def effort_choices(state), do: Alto.Reasoning.efforts(model_metadata(state))

  def effort_key(state),
    do: {state.selected_backend, state.selected_provider_id, state.selected_model}

  def selected_effort(state) do
    value = Map.get(state.efforts, effort_key(state))
    if value in effort_choices(state), do: value, else: nil
  end

  def activity(state) do
    case Enum.find(state.runs, fn {_id, run} -> run.task_id == state.selected_task_id end) do
      {_id, run} ->
        {run_label(state), Map.get(run, :started_at_ms)}

      nil ->
        activity = Alto.TUI.Backend.ui(state, :activity)

        cond do
          activity not in [:pass, nil] ->
            {activity, state.activity_started_ms}

          MapSet.size(state.model_loading) > 0 ->
            {"loading model catalog", state.activity_started_ms}

          true ->
            nil
        end
    end
  end

  @doc "Currently selected project, if any."
  def selected_project(%__MODULE__{} = state),
    do: Enum.find(state.projects, &(&1["id"] == state.selected_project_id))

  @doc "Currently selected task, if any."
  def selected_task(%__MODULE__{} = state) do
    state.tasks
    |> Map.get(state.selected_project_id, [])
    |> Enum.find(&(&1["id"] == state.selected_task_id))
  end

  @doc "Currently selected provider profile, if any."
  def selected_profile(%__MODULE__{} = state),
    do: Enum.find(state.profiles, &(&1.id == state.selected_provider_id))

  def open_projects(state), do: Enum.reject(state.projects, &(&1["closed"] == true))

  def close_workspace(state, nil),
    do: %{state | leader?: false, overlay: nil, notice: "No workspace to close"}

  def close_workspace(state, id) do
    case Catalog.close_project(id, state.catalog_opts) do
      {:ok, closed} ->
        next = %{
          state
          | projects: Enum.map(state.projects, &if(&1["id"] == id, do: closed, else: &1)),
            overlay: nil,
            leader?: false
        }

        next =
          if state.selected_project_id == id do
            project = List.first(open_projects(next))

            %{next | selected_project_id: project && project["id"], details_scroll: 0}
            |> new_task()
          else
            next
          end

        %{next | notice: "Workspace closed · reopen its folder to return"}

      {:error, reason} ->
        %{
          state
          | leader?: false,
            notice: "Could not close workspace: #{Alto.Display.error(reason)}"
        }
    end
  end

  @doc "Navigation rows in their exact on-screen order."
  def rail_rows(%__MODULE__{} = state) do
    Enum.flat_map(open_projects(state), fn project ->
      project_row = %{kind: :project, id: project["id"], label: "▾ " <> project["name"]}

      if project["id"] == state.selected_project_id do
        task_rows =
          state.tasks
          |> Map.get(project["id"], [])
          |> Enum.map(fn task ->
            marker = status_marker(task["status"])
            %{kind: :task, id: task["id"], label: "  #{marker} #{task["title"]}"}
          end)

        [project_row | task_rows]
      else
        [%{project_row | label: "▸ " <> project["name"]}]
      end
    end)
  end

  @doc "Select a rail row and lazily hydrate its persisted transcript."
  def select_rail_row(%__MODULE__{} = state, index) when is_integer(index) do
    case Enum.at(rail_rows(state), index) do
      %{kind: :project, id: id} -> select_project(state, id)
      %{kind: :task, id: id} -> select_task(state, id)
      _ -> state
    end
  end

  def select_project(%__MODULE__{} = state, id) do
    case Enum.find(state.projects, &(&1["id"] == id)) do
      nil ->
        state

      _project ->
        %{
          state
          | selected_project_id: id,
            selected_task_id: nil,
            transcript_scroll: 0,
            transcript_follow?: true
        }
    end
  end

  def select_task(%__MODULE__{} = state, id) do
    if Enum.any?(Map.get(state.tasks, state.selected_project_id, []), &(&1["id"] == id)) do
      task = Enum.find(Map.get(state.tasks, state.selected_project_id, []), &(&1["id"] == id))

      state
      |> Map.put(:selected_task_id, id)
      |> Map.put(:transcript_follow?, true)
      |> sync_backend(task)
      |> hydrate_selected()
    else
      state
    end
  end

  @doc "Leave the current task selected project intact and compose a new task."
  def new_task(%__MODULE__{} = state) do
    %{
      state
      | selected_task_id: nil,
        overlay: nil,
        leader?: false,
        notice: "new task — your draft is preserved",
        focus: :composer,
        transcript_scroll: 0,
        transcript_follow?: true
    }
  end

  @doc "Open a folder as a workspace and prepare a new task without losing the draft."
  def open_workspace(state, path) do
    base =
      case selected_project(state) do
        nil -> File.cwd!()
        project -> project["root"]
      end

    if is_binary(path) and byte_size(path) <= 4096 and String.trim(path) != "" and
         not String.contains?(path, ["\n", "\r", <<0>>]) do
      root = Path.expand(path, base)

      with {:ok, project} <- Catalog.register_project(root, state.catalog_opts),
           {:ok, projects} <- Catalog.projects(state.catalog_opts),
           {:ok, tasks} <- load_tasks(projects, state.catalog_opts) do
        {:ok,
         %{state | projects: projects, tasks: tasks, selected_project_id: project["id"]}
         |> close_details_drawer()
         |> new_task()
         |> Map.put(:notice, "Workspace: " <> root)}
      end
    else
      {:error, :invalid_workspace_path}
    end
  end

  @doc "Entries displayed for the selected task or scratch composer."
  def current_entries(%__MODULE__{} = state),
    do: Map.get(state.entries, state.selected_task_id || :scratch, [])

  @doc "Transcript plus transient pending input, kept outside the streamed conversation."
  def visible_entries(%__MODULE__{} = state) do
    current_entries(state) ++ pending_entries(state)
  end

  defp pending_entries(state) do
    pending =
      case Map.get(state.inputs, state.selected_task_id) do
        nil -> []
        input -> Alto.Input.list(input)
      end

    Enum.map(pending, fn entry ->
      label = if entry.mode == :steer, do: "Steering message: ", else: "Queued message: "
      %{kind: :system, text: label <> entry.text}
    end)
  catch
    :exit, _ -> []
  end

  def put_entries(%__MODULE__{} = state, task_id, entries),
    do:
      %{state | entries: Map.put(state.entries, task_id || :scratch, bounded_entries(entries))}
      |> evict_inactive_caches()

  def append_entry(%__MODULE__{} = state, task_id, entry) do
    key = task_id || :scratch
    entries = bounded_entries(Map.get(state.entries, key, []) ++ [entry])
    %{state | entries: Map.put(state.entries, key, entries)} |> evict_inactive_caches()
  end

  def upsert_entry(%__MODULE__{} = state, task_id, key, entry) do
    task_key = task_id || :scratch
    tagged = Map.put(entry, :entry_key, key)
    entries = Map.get(state.entries, task_key, [])

    entries =
      if Enum.any?(entries, &(&1[:entry_key] == key)) do
        Enum.map(entries, &if(&1[:entry_key] == key, do: tagged, else: &1))
      else
        entries ++ [tagged]
      end

    %{state | entries: Map.put(state.entries, task_key, bounded_entries(entries))}
    |> evict_inactive_caches()
  end

  def append_assistant_delta(%__MODULE__{} = state, task_id, text, kind \\ :assistant) do
    key = task_id || :scratch
    entries = Map.get(state.entries, key, [])

    entries =
      case List.pop_at(entries, -1) do
        {%{kind: ^kind} = last, rest} -> rest ++ [%{last | text: last.text <> text}]
        {_last, _rest} -> entries ++ [%{kind: kind, text: text}]
      end

    %{state | entries: Map.put(state.entries, key, bounded_entries(entries))}
    |> evict_inactive_caches()
  end

  def put_task(%__MODULE__{} = state, task) do
    state = update_task_record(state, task)
    %{state | selected_project_id: task["project_id"], selected_task_id: task["id"]}
  end

  @doc "Replace a task record without changing the front end's current selection."
  def update_task_record(%__MODULE__{} = state, task) do
    project_id = task["project_id"]

    tasks =
      Map.update(state.tasks, project_id, [task], fn items ->
        [task | Enum.reject(items, &(&1["id"] == task["id"]))]
      end)

    %{state | tasks: tasks}
  end

  def update_usage(%__MODULE__{} = state, task_id, usage) when is_map(usage) do
    next = Usage.from_map(usage)

    %{state | usage: Map.update(state.usage, task_id, next, &Usage.merge(&1, next))}
    |> evict_inactive_caches()
  end

  @doc "Replace token accounting with an authoritative backend snapshot."
  def put_usage(%__MODULE__{} = state, task_id, %Usage{} = usage),
    do: %{state | usage: Map.put(state.usage, task_id, usage)} |> evict_inactive_caches()

  def current_usage(%__MODULE__{} = state),
    do: Map.get(state.usage, state.selected_task_id, Usage.new())

  def task_backend(%{"backend" => backend}) when is_binary(backend) do
    String.to_existing_atom(backend)
  rescue
    ArgumentError -> :unavailable
  end

  def focus_next(%__MODULE__{} = state, direction \\ :next) do
    step = if direction == :previous, do: -1, else: 1
    start = Enum.find_index(@focuses, &(&1 == state.focus)) || 0
    visible = visible_focuses(state)

    next =
      1..length(@focuses)
      |> Enum.map(&Integer.mod(start + &1 * step, length(@focuses)))
      |> Enum.map(&Enum.at(@focuses, &1))
      |> Enum.find(&(&1 in visible))

    %{state | focus: next || :composer}
  end

  @doc "Move focus away from a pane omitted by the responsive layout."
  def ensure_visible_focus(%__MODULE__{} = state) do
    if state.focus in visible_focuses(state) do
      state
    else
      direction = if state.focus == :details, do: :previous, else: :next
      focus_next(state, direction)
    end
  end

  @doc "Open narrow-terminal context as a modal drawer and remember where to return."
  def open_details_drawer(%__MODULE__{} = state, opts \\ []) do
    return_focus = if state.focus == :details, do: state.details_return_focus, else: state.focus
    auto_opened? = state.details_drawer_auto_opened? or Keyword.get(opts, :auto, false)

    %{
      state
      | details_visible?: true,
        details_drawer_open?: true,
        details_drawer_auto_opened?: auto_opened?,
        details_return_focus: return_focus || :composer,
        focus: :details
    }
  end

  @doc "Close the context drawer and restore its prior visible focus."
  def close_details_drawer(%__MODULE__{} = state) do
    state = %{
      state
      | details_drawer_open?: false,
        details_drawer_auto_opened?: false,
        focus: state.details_return_focus || :composer,
        details_return_focus: nil
    }

    ensure_visible_focus(state)
  end

  @doc "Keep actively focused context visible while crossing responsive breakpoints."
  def reconcile_responsive_focus(%__MODULE__{} = state) do
    cond do
      details_pane_visible?(state) and state.details_drawer_open? ->
        %{
          state
          | details_drawer_open?: false,
            details_drawer_auto_opened?: false,
            details_return_focus: nil
        }

      not details_pane_visible?(state) and state.focus == :details and
          not state.details_drawer_open? ->
        open_details_drawer(state)

      true ->
        ensure_visible_focus(state)
    end
  end

  @doc "Whether the responsive layout currently allocates the persistent context pane."
  def details_pane_visible?(%__MODULE__{} = state),
    do: not is_nil(responsive_layout(state).details)

  @doc "Focus targets rendered at the state's current terminal dimensions."
  def visible_focuses(%__MODULE__{} = state) do
    if state.details_drawer_open? do
      [:details]
    else
      layout = responsive_layout(state)

      Enum.filter(@focuses, fn
        :rail -> not is_nil(layout.rail)
        :details -> not is_nil(layout.details)
        _other -> true
      end)
    end
  end

  defp responsive_layout(state) do
    {width, height} = state.dimensions

    Alto.TUI.Layout.calculate(width, height,
      rail_visible: state.rail_visible?,
      details_visible: state.details_visible?,
      rail_width: state.rail_width,
      details_width: state.details_width
    )
  end

  defp hydrate_selected(%__MODULE__{selected_task_id: nil} = state), do: state

  defp hydrate_selected(%__MODULE__{} = state) do
    state
    |> hydrate_selected_entries()
    |> hydrate_selected_usage()
  end

  defp hydrate_selected_entries(state) do
    if Map.has_key?(state.entries, state.selected_task_id) do
      state
    else
      case selected_task(state) do
        %{"conversation_id" => conversation_id} = task when is_binary(conversation_id) ->
          entries =
            if Alto.TUI.Backend.runner?(state.run_options, task_backend(task)),
              do: load_session_entries(conversation_id, state.catalog_opts),
              else: []

          put_entries(state, state.selected_task_id, entries)

        _other ->
          put_entries(state, state.selected_task_id, [])
      end
    end
  end

  defp hydrate_selected_usage(state) do
    if Map.has_key?(state.usage, state.selected_task_id) do
      state
    else
      usage =
        case selected_task(state) do
          %{"conversation_id" => conversation_id} = task when is_binary(conversation_id) ->
            if Alto.TUI.Backend.ui(
                 %{state | selected_backend: task_backend(task)},
                 :session_usage?
               ) == true,
               do: load_session_usage(conversation_id, state.catalog_opts),
               else: Usage.new()

          _other ->
            Usage.new()
        end

      put_usage(state, state.selected_task_id, usage)
    end
  end

  defp load_session_entries(session_id, opts) do
    case Session.transcript(session_id, Keyword.take(opts, [:session_dir])) do
      {:ok, %{messages: messages}} -> Alto.ToolDisplay.transcript(messages)
      _error -> []
    end
  end

  defp load_session_usage(session_id, opts) do
    case Session.read(session_id, Keyword.take(opts, [:session_dir])) do
      {:ok, records} -> Enum.reduce(records, Usage.new(), &merge_record_usage/2)
      _error -> Usage.new()
    end
  end

  defp merge_record_usage(
         %{"type" => "event", "event" => "model_completed", "data" => encoded},
         usage
       ) do
    case Session.decode_term(encoded) do
      {:ok, %{usage: event_usage}} when is_map(event_usage) ->
        Usage.merge(usage, Usage.from_map(event_usage))

      _other ->
        usage
    end
  end

  defp merge_record_usage(_record, usage), do: usage

  defp load_tasks(projects, opts) do
    Enum.reduce_while(projects, {:ok, %{}}, fn project, {:ok, acc} ->
      case Catalog.tasks(project["id"], opts) do
        {:ok, tasks} -> {:cont, {:ok, Map.put(acc, project["id"], tasks)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp bounded_entries(entries) when is_list(entries) do
    entries
    |> Enum.take(-@max_entries_per_task)
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn entry, {acc, bytes} ->
      entry = Map.new(entry, fn {key, value} -> {key, bounded_value(value)} end)
      size = :erlang.external_size(entry)

      if bytes + size <= 2_000_000,
        do: {:cont, {[entry | acc], bytes + size}},
        else: {:halt, {acc, bytes}}
    end)
    |> elem(0)
  end

  defp bounded_entries(_), do: []

  defp bounded_value(value) when is_binary(value),
    do: Alto.Text.truncate(value, 64_000, "\n[display shortened; see session log]")

  defp bounded_value(value), do: value

  defp evict_inactive_caches(%__MODULE__{} = state) do
    active = Enum.map(state.runs, fn {_id, run} -> run.task_id end)
    keep = MapSet.new([state.selected_task_id || :scratch | active])
    cached = Enum.uniq(Map.keys(state.entries) ++ Map.keys(state.usage))
    inactive = Enum.reject(cached, &MapSet.member?(keep, &1))
    drop = Enum.take(Enum.sort(inactive), max(length(cached) - @max_cached_tasks, 0))
    %{state | entries: Map.drop(state.entries, drop), usage: Map.drop(state.usage, drop)}
  end

  defp initial_models(profiles) do
    Map.new(profiles, fn profile ->
      {profile.id, if(is_list(profile.models), do: profile.models, else: [])}
    end)
    |> Map.reject(fn {_id, models} -> models == [] end)
  end

  defp sync_backend(state, task) do
    backend = task_backend(task)

    state = %{state | selected_backend: backend}

    model =
      case Alto.TUI.Backend.ui(state, :sync_model) do
        :pass ->
          profile = selected_profile(state)
          profile && profile.default_model

        model ->
          model
      end

    %{state | selected_model: model}
  end

  defp status_marker("completed"), do: "✓"
  defp status_marker("failed"), do: "!"
  defp status_marker("waiting"), do: "?"
  defp status_marker(_status), do: "·"
end
