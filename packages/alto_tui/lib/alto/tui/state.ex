defmodule Alto.TUI.State do
  @moduledoc "State and catalog projection for the Alto terminal client."

  alias Alto.Harness.Catalog
  alias Alto.Harness.{ProviderProfile, ProviderStore}
  alias Alto.Session
  alias Alto.Usage

  @focuses [:rail, :transcript, :details, :composer]
  @max_entries_per_task 2_000
  @max_cached_tasks 12

  @enforce_keys [:textarea, :config, :run_options, :catalog_opts]
  defstruct [
    :textarea,
    :config,
    :run_options,
    :credentials_path,
    :selected_project_id,
    :selected_task_id,
    :selected_provider_id,
    :selected_model,
    :selected_backend,
    :codex,
    :overlay,
    :dragging,
    :notice,
    dimensions: {120, 36},
    projects: [],
    tasks: %{},
    entries: %{},
    profiles: [],
    models: %{},
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
    runs: %{},
    queued_messages: %{},
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
      codex_options = Keyword.get(run_options, :codex_backend, [])
      tui_options = Keyword.get(run_options, :tui, [])
      selected_backend = task_backend(selected_task)

      state = %__MODULE__{
        textarea: ExRatatui.textarea_new(),
        config: config,
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
        selected_model:
          if(selected_backend == :codex,
            do: Keyword.get(codex_options, :model),
            else: profile && profile.default_model
          ),
        selected_backend: selected_backend,
        codex: %{
          options: codex_options,
          client: nil,
          status: :idle,
          account: nil,
          models: [],
          rate_limits: nil,
          context_window: nil,
          login: nil,
          loaded_threads: MapSet.new(),
          history_loading: MapSet.new(),
          pending_events: [],
          pending_requests: []
        },
        usage: %{}
      }

      {:ok, hydrate_selected(state)}
    end
  end

  @doc "Visible execution stage and recovery controls for the selected task."
  def run_label(state) do
    queued? = Map.has_key?(state.queued_messages, state.selected_task_id)

    case Enum.find(state.runs, fn {_id, run} -> run.task_id == state.selected_task_id end) do
      nil ->
        if queued?, do: "message queued · Enter send", else: "idle"

      {_id, run} ->
        Map.get(run, :phase, "working") <>
          " · Esc stop" <>
          if(queued?, do: " · 1 queued", else: "")
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

  @doc "Navigation rows in their exact on-screen order."
  def rail_rows(%__MODULE__{} = state) do
    Enum.flat_map(state.projects, fn project ->
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
      nil -> state
    end
  end

  def select_project(%__MODULE__{} = state, id) do
    case Enum.find(state.projects, &(&1["id"] == id)) do
      nil ->
        state

      _project ->
        task = state.tasks |> Map.get(id, []) |> List.first()

        state
        |> Map.put(:selected_project_id, id)
        |> Map.put(:selected_task_id, task && task["id"])
        |> Map.put(:transcript_follow?, true)
        |> sync_backend(task)
        |> hydrate_selected()
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
        notice: "new task — your draft is preserved",
        focus: :composer,
        transcript_scroll: 0,
        transcript_follow?: true
    }
  end

  @doc "Entries displayed for the selected task or scratch composer."
  def current_entries(%__MODULE__{} = state),
    do: Map.get(state.entries, state.selected_task_id || :scratch, [])

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
    project_id = task["project_id"]

    tasks =
      Map.update(state.tasks, project_id, [task], fn items ->
        [task | Enum.reject(items, &(&1["id"] == task["id"]))]
      end)

    %{state | tasks: tasks, selected_project_id: project_id, selected_task_id: task["id"]}
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

  @doc "Execution backend persisted with a task; legacy tasks are native Alto tasks."
  def task_backend(%{"backend" => backend}) when is_binary(backend) do
    String.to_existing_atom(backend)
  rescue
    ArgumentError -> :unavailable
  end

  def task_backend(_task), do: :alto

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
        %{"session_id" => session_id} when is_binary(session_id) ->
          entries = load_session_entries(session_id, state.catalog_opts)
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
          %{"session_id" => session_id} = task when is_binary(session_id) ->
            if task_backend(task) == :alto,
              do: load_session_usage(session_id, state.catalog_opts),
              else: Usage.new()

          _other ->
            Usage.new()
        end

      put_usage(state, state.selected_task_id, usage)
    end
  end

  defp load_session_entries(session_id, opts) do
    case Session.transcript(session_id, Keyword.take(opts, [:session_dir])) do
      {:ok, %{messages: messages}} -> Enum.flat_map(messages, &message_entries/1)
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

      {:ok, %{"usage" => event_usage}} when is_map(event_usage) ->
        Usage.merge(usage, Usage.from_map(event_usage))

      _other ->
        usage
    end
  end

  defp merge_record_usage(_record, usage), do: usage

  defp message_entries(%{"role" => "user", "content" => text}) when is_binary(text),
    do: [%{kind: :user, text: text}]

  defp message_entries(%{"role" => "assistant", "content" => text}) when is_binary(text),
    do: [%{kind: :assistant, text: text}]

  defp message_entries(%{"role" => "tool", "content" => text}) when is_binary(text),
    do: [%{kind: :tool, text: text}]

  defp message_entries(_message), do: []

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

  defp bounded_value(value) when is_binary(value) and byte_size(value) > 64_000 do
    prefix = binary_part(value, 0, 63_950) |> valid_utf8_prefix()
    prefix <> "\n[display shortened; see session log]"
  end

  defp bounded_value(value), do: value

  defp valid_utf8_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_utf8_prefix(binary_part(value, 0, byte_size(value) - 1))
  end

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

    model =
      case backend do
        :codex ->
          current = state.selected_model

          if Enum.any?(state.codex.models, &((&1[:id] || &1["id"]) == current)),
            do: current,
            else: codex_default_model(state)

        _local ->
          profile = selected_profile(state)
          profile && profile.default_model
      end

    %{state | selected_backend: backend, selected_model: model}
  end

  defp codex_default_model(state) do
    configured = Keyword.get(state.codex.options, :model)

    configured ||
      case Enum.find(state.codex.models, &Map.get(&1, :default?, false)) ||
             List.first(state.codex.models) do
        nil -> nil
        model -> model[:id] || model["id"]
      end
  end

  defp status_marker("completed"), do: "✓"
  defp status_marker("failed"), do: "!"
  defp status_marker("waiting"), do: "?"
  defp status_marker(_status), do: "·"
end
