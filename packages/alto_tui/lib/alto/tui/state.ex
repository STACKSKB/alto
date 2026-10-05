defmodule Alto.TUI.State do
  @moduledoc "State and catalog projection for the Alto terminal client."

  alias Alto.TUI.Catalog
  alias Alto.Contrib.ProviderProfile
  alias Alto.Contrib.ProviderStore
  alias Alto.Session
  alias Alto.Usage
  alias Alto.TUI.Preferences

  @focuses [:rail, :transcript, :details, :composer]
  @max_entries_per_task 2_000
  @max_cached_tasks 12
  @tui_options NimbleOptions.new!(
                 render_cache_bytes: [type: :non_neg_integer],
                 history_cache_bytes: [type: :non_neg_integer],
                 type_to_compose: [type: :boolean],
                 narrow_context: [type: {:in, [:adaptive, :drawer, :fullscreen]}],
                 narrow_context_width: [type: {:in, 40..100}],
                 narrow_context_fullscreen_below: [type: {:in, 0..300}],
                 paste_inline_bytes: [type: :pos_integer],
                 paste_chunk_bytes: [type: {:in, 4..1_000_000}],
                 approval_auto_open: [type: :boolean],
                 approval_reviewer: [type: {:fun, 2}]
               )

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
    :search,
    :worktree_creation,
    :dragging,
    :notice,
    :clipboard_text,
    :clipboard_write,
    :clipboard_read,
    :drag_poll,
    :history_load,
    :stream_frame,
    attachments: [],
    paste_inline_bytes: 4_096,
    paste_chunk_bytes: 32_000,
    stream_events: [],
    stream_tails: %{},
    stream_bytes: 0,
    async_history?: false,
    render_cache_bytes: 16_000_000,
    history_cache_bytes: 12_000_000,
    activity_tick: 0,
    activity_started_ms: nil,
    selection: %Alto.TUI.Selection{},
    dimensions: {120, 36},
    projects: [],
    tasks: %{},
    entries: %{},
    entry_bytes: %{},
    cache_order: [],
    subagents: %{},
    subagent_bytes: %{},
    selected_agent_id: nil,
    profiles: [],
    preferences: %{},
    models: %{},
    efforts: %{},
    model_loading: MapSet.new(),
    approval_level: :ask,
    approval_override?: false,
    composer_mode: :prose,
    type_to_compose?: true,
    narrow_context: :adaptive,
    narrow_context_width: 75,
    narrow_context_fullscreen_below: 72,
    approval_auto_open?: true,
    focus: :composer,
    leader?: false,
    details_visible?: true,
    details_drawer_auto_opened?: false,
    details_return_focus: nil,
    rail_visible?: true,
    rail_width: 26,
    details_width: 36,
    transcript_scroll: 0,
    transcript_follow?: true,
    details_scroll: 0,
    pending_approvals: [],
    approval_reviews: %{},
    backend_state: %{},
    runs: %{},
    input_routes: %{},
    inputs: %{},
    usage: %{},
    catalog_opts: []
  ]

  @type t :: %__MODULE__{}

  @doc "Build TUI state and register the initial project root."
  @spec new(keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(run_options, opts \\ []) when is_list(run_options) do
    tui_options = run_options |> Keyword.get(:tui, []) |> NimbleOptions.validate!(@tui_options)
    catalog_opts = catalog_options(run_options, opts)

    root = opts |> Keyword.get(:project, File.cwd!()) |> Path.expand()

    credentials_path =
      Keyword.get(opts, :credentials_path, Alto.Contrib.Credentials.default_path())

    if not Alto.TUI.Backend.valid?(Alto.TUI.Backend.configured(run_options)),
      do: raise(ArgumentError, "invalid tui_backends")

    with {:ok, configured_profiles} <- ProviderProfile.from_run_options(run_options),
         {:ok, profiles} <-
           ProviderStore.profiles(configured_profiles, credentials_path: credentials_path),
         {:ok, selected_project} <- Catalog.register_project(root, catalog_opts),
         {:ok, projects, tasks} <- Catalog.navigation(catalog_opts) do
      selected_task = tasks |> Map.get(selected_project["id"], []) |> List.first()

      preferences =
        case Preferences.load(catalog_opts) do
          {:ok, saved} -> saved
          {:error, _} -> %{}
        end

      profile = Enum.find(profiles, &(&1.id == preferences["provider"])) || List.first(profiles)

      selected_backend =
        if selected_task,
          do: task_backend(selected_task),
          else:
            Enum.find(
              Keyword.keys(Alto.TUI.Backend.configured(run_options)),
              &(to_string(&1) == preferences["backend"])
            ) ||
              List.first(Keyword.keys(Alto.TUI.Backend.configured(run_options)))

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
        async_history?: Keyword.get(opts, :async_history, false),
        render_cache_bytes: Keyword.get(tui_options, :render_cache_bytes, 16_000_000),
        history_cache_bytes: Keyword.get(tui_options, :history_cache_bytes, 12_000_000),
        projects: projects,
        tasks: tasks,
        selected_project_id: selected_project["id"],
        selected_task_id: selected_task && selected_task["id"],
        profiles: profiles,
        preferences: preferences,
        selected_provider_id: profile && profile.id,
        type_to_compose?: Keyword.get(tui_options, :type_to_compose, true),
        narrow_context: Keyword.get(tui_options, :narrow_context, :adaptive),
        narrow_context_width: Keyword.get(tui_options, :narrow_context_width, 75),
        narrow_context_fullscreen_below:
          Keyword.get(tui_options, :narrow_context_fullscreen_below, 72),
        paste_inline_bytes: Keyword.get(tui_options, :paste_inline_bytes, 4_096),
        paste_chunk_bytes: Keyword.get(tui_options, :paste_chunk_bytes, 32_000),
        approval_auto_open?: Keyword.get(tui_options, :approval_auto_open, true),
        selected_model: profile && profile.default_model,
        selected_backend: selected_backend,
        usage: %{}
      }

      state = Alto.TUI.Backend.initialize(state)
      {:ok, state |> restore_model() |> hydrate_selected()}
    end
  end

  @doc false
  def catalog_options(run_options, opts) do
    opts
    |> Keyword.take([:path, :session_dir])
    |> Keyword.put_new_lazy(:session_dir, fn ->
      Keyword.get(run_options, :session_dir)
    end)
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
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
  def input_pending?(%__MODULE__{} = state, task_id), do: pending_input(state, task_id) != []

  defp pending_input(state, task_id) do
    case Map.get(state.inputs, task_id) do
      nil -> []
      input -> Alto.Input.request(input, :list)
    end
  catch
    :exit, _ -> []
  end

  def model_metadata(state) do
    models =
      with :pass <- Alto.TUI.Backend.ui(state, :models) do
        profile = selected_profile(state)
        profile && known_models(state, profile)
      end

    if is_list(models),
      do: Enum.find(models, &(&1.id == state.selected_model))
  end

  @doc "Models already fetched or embedded in a provider profile."
  def known_models(state, profile), do: Map.get(state.models, profile.id, profile.models)

  def effort_choices(state), do: Alto.Contrib.Reasoning.efforts(model_metadata(state))

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

          state.history_load != nil and state.history_load.id == state.selected_task_id ->
            {"loading saved history", state.activity_started_ms}

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
            notice: "Could not close workspace: #{Alto.Contrib.Display.error(reason)}"
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
  def select_rail_row(state, %{kind: :project, id: id}), do: select_project(state, id)
  def select_rail_row(state, %{kind: :task, id: id}), do: select_task(state, id)
  def select_rail_row(state, _row), do: state

  def select_project(%__MODULE__{} = state, id) do
    case Enum.find(state.projects, &(&1["id"] == id)) do
      nil ->
        state

      _project ->
        state = state |> Alto.TUI.Search.close() |> Alto.TUI.History.cancel()

        %{
          state
          | selected_project_id: id,
            selected_task_id: nil,
            search: nil,
            transcript_scroll: 0,
            transcript_follow?: true
        }
    end
  end

  def select_task(%__MODULE__{} = state, id) do
    case Enum.find(Map.get(state.tasks, state.selected_project_id, []), &(&1["id"] == id)) do
      nil ->
        state

      task ->
        state
        |> Alto.TUI.Search.close()
        |> Map.put(:selected_task_id, id)
        |> Map.put(:selected_agent_id, nil)
        |> Map.put(:search, nil)
        |> Map.put(:transcript_follow?, true)
        |> sync_backend(task)
        |> touch_cache(id)
        |> hydrate_selected()
    end
  end

  @doc "Leave the current task selected project intact and compose a new task."
  def new_task(%__MODULE__{} = state) do
    state = state |> Alto.TUI.Search.close() |> Alto.TUI.History.cancel()

    %{
      state
      | selected_task_id: nil,
        selected_agent_id: nil,
        search: nil,
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
           {:ok, projects, tasks} <- Catalog.navigation(state.catalog_opts) do
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
    do: task_entries(state, state.selected_task_id)

  @doc "Materialize a task's displayed history, including its separately owned live tail."
  def task_entries(%__MODULE__{} = state, task_id) do
    key = task_id || :scratch

    case Map.get(state.stream_tails, key) do
      %{prefix: prefix, entry: entry} -> prefix ++ [entry]
      nil -> Map.get(state.entries, key, [])
    end
  end

  @doc "Transcript plus transient pending input, kept outside the streamed conversation."
  def visible_entries(%__MODULE__{} = state) do
    current_entries(state) ++ pending_entries(state)
  end

  defp pending_entries(state) do
    Enum.map(pending_input(state, state.selected_task_id), fn entry ->
      label = if entry.mode == :steer, do: "Steering message: ", else: "Queued message: "
      %{kind: :system, text: label <> entry.text}
    end)
  end

  def put_entries(%__MODULE__{} = state, task_id, entries) do
    key = task_id || :scratch
    entries = bounded_entries(entries)

    %{
      state
      | entries: Map.put(state.entries, key, entries),
        entry_bytes: Map.put(state.entry_bytes, key, :erlang.external_size(entries)),
        stream_tails: Map.delete(state.stream_tails, key)
    }
    |> touch_cache(key)
    |> evict_inactive_caches()
  end

  def put_subagents(state, task, agents) do
    %{
      state
      | subagents: Map.put(state.subagents, task, agents),
        subagent_bytes: Map.put(state.subagent_bytes, task, :erlang.external_size(agents))
    }
    |> evict_inactive_caches()
  end

  def put_agent(state, task, key, agent) do
    agents = Map.get(state.subagents, task, %{})
    bytes = Map.get_lazy(state.subagent_bytes, task, fn -> :erlang.external_size(agents) end)
    old = if Map.has_key?(agents, key), do: :erlang.external_size({key, agents[key]}), else: 0

    %{
      state
      | subagents: Map.put(state.subagents, task, Map.put(agents, key, agent)),
        subagent_bytes:
          Map.put(state.subagent_bytes, task, bytes - old + :erlang.external_size({key, agent}))
    }
    |> evict_inactive_caches()
  end

  def append_entry(%__MODULE__{} = state, task_id, entry) do
    key = task_id || :scratch
    put_entries(state, key, task_entries(state, key) ++ [entry])
  end

  def upsert_entry(%__MODULE__{} = state, task_id, key, entry) do
    task_key = task_id || :scratch
    tagged = Map.put(entry, :entry_key, key)
    entries = task_entries(state, task_key)

    entries =
      if Enum.any?(entries, &(&1[:entry_key] == key)) do
        Enum.map(entries, &if(&1[:entry_key] == key, do: tagged, else: &1))
      else
        entries ++ [tagged]
      end

    put_entries(state, task_key, entries)
  end

  def append_assistant_delta(%__MODULE__{} = state, task_id, text, kind \\ :assistant) do
    key = task_id || :scratch

    tail =
      case Map.get(state.stream_tails, key) do
        %{kind: ^kind} = tail ->
          tail

        _ ->
          entries = task_entries(state, key)

          {entry, prefix} =
            case List.pop_at(entries, -1) do
              {%{kind: ^kind} = last, prefix} -> {last, prefix}
              _ -> {%{kind: kind, text: ""}, entries}
            end

          %{
            kind: kind,
            entry: entry,
            truncated?: false,
            prefix: prefix,
            count: length(prefix),
            bytes: Enum.reduce(prefix, 0, &(:erlang.external_size(&1) + &2))
          }
      end

    combined = if tail.truncated?, do: tail.entry.text, else: tail.entry.text <> text
    entry = %{tail.entry | text: bounded_value(combined)}
    tail = %{tail | truncated?: tail.truncated? or byte_size(combined) > 64_000}
    tail = trim_stream_prefix(tail, :erlang.external_size(entry))
    tail = %{tail | entry: entry}

    %{
      state
      | entries: Map.put(state.entries, key, tail.prefix),
        entry_bytes: Map.put(state.entry_bytes, key, tail.bytes + :erlang.external_size(entry)),
        stream_tails: Map.put(state.stream_tails, key, tail)
    }
    |> evict_inactive_caches()
  end

  defp trim_stream_prefix(tail, bytes)
       when tail.count < @max_entries_per_task and tail.bytes + bytes <= 2_000_000,
       do: tail

  defp trim_stream_prefix(%{prefix: [entry | rest]} = tail, bytes),
    do:
      trim_stream_prefix(
        %{
          tail
          | prefix: rest,
            count: tail.count - 1,
            bytes: tail.bytes - :erlang.external_size(entry)
        },
        bytes
      )

  defp trim_stream_prefix(tail, _), do: tail

  def put_task(%__MODULE__{} = state, task) do
    state = update_task_record(state, task)
    %{state | selected_project_id: task["project_id"], selected_task_id: task["id"]}
  end

  @doc "Persist task changes and refresh their cached record without changing selection."
  def update_task(state, task_id, changes) do
    case Catalog.update_task(task_id, changes, state.catalog_opts) do
      {:ok, task} -> update_task_record(state, task)
      {:error, _reason} -> state
    end
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
    next = Usage.normalize(usage)

    %{state | usage: Map.update(state.usage, task_id, next, &Usage.merge(&1, next))}
    |> evict_inactive_caches()
  end

  @doc "Replace token accounting with an authoritative backend snapshot."
  def put_usage(%__MODULE__{} = state, task_id, usage) when is_map(usage),
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
        details_drawer_auto_opened?: auto_opened?,
        details_return_focus: return_focus || :composer,
        focus: :details
    }
  end

  @doc "Close the context drawer and restore its prior visible focus."
  def close_details_drawer(%__MODULE__{details_return_focus: nil} = state), do: state

  def close_details_drawer(%__MODULE__{} = state) do
    state = %{
      state
      | details_drawer_auto_opened?: false,
        focus: state.details_return_focus || :composer,
        details_return_focus: nil
    }

    ensure_visible_focus(state)
  end

  @doc "Keep actively focused context visible while crossing responsive breakpoints."
  def reconcile_responsive_focus(%__MODULE__{} = state) do
    cond do
      details_pane_visible?(state) and state.details_return_focus ->
        %{
          state
          | details_drawer_auto_opened?: false,
            details_return_focus: nil
        }

      not details_pane_visible?(state) and state.focus == :details and
          is_nil(state.details_return_focus) ->
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
    if state.details_return_focus do
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

  @doc false
  def hydrate_selected(%__MODULE__{selected_task_id: nil} = state),
    do: Alto.TUI.History.cancel(state)

  def hydrate_selected(%__MODULE__{async_history?: true} = state) do
    task = selected_task(state)

    if task && is_binary(task["conversation_id"]) &&
         Alto.TUI.Backend.runner?(state.run_options, task_backend(task)) do
      state |> Alto.TUI.History.request(task) |> evict_inactive_caches()
    else
      state |> Alto.TUI.History.cancel() |> hydrate_sync()
    end
  end

  def hydrate_selected(state), do: hydrate_sync(state)

  defp hydrate_sync(%__MODULE__{} = state) do
    task = selected_task(state)
    session_id = task && task["conversation_id"]
    backend = task && task_backend(task)

    entries =
      Map.put_new_lazy(state.entries, state.selected_task_id, fn ->
        if is_binary(session_id) and Alto.TUI.Backend.runner?(state.run_options, backend),
          do: load_session_entries(session_id, state.catalog_opts),
          else: []
      end)

    usage =
      Map.put_new_lazy(state.usage, state.selected_task_id, fn ->
        if is_binary(session_id) and
             Alto.TUI.Backend.ui(
               %{state | selected_backend: backend, entries: entries},
               :session_usage?
             ) ==
               true,
           do: load_session_usage(session_id, state.catalog_opts),
           else: Usage.new()
      end)

    sizes =
      Map.new(entries, fn {id, entries} ->
        {id, Map.get_lazy(state.entry_bytes, id, fn -> :erlang.external_size(entries) end)}
      end)

    state = %{state | entries: entries, entry_bytes: sizes, usage: usage}

    state =
      if is_binary(session_id) and Alto.TUI.Backend.runner?(state.run_options, backend) and
           not Map.has_key?(state.subagents, state.selected_task_id) do
        {agents, warnings} = Alto.TUI.Subagents.load(session_id, state.catalog_opts)

        %{
          state
          | subagents: Map.put(state.subagents, state.selected_task_id, agents),
            subagent_bytes:
              Map.put(state.subagent_bytes, state.selected_task_id, :erlang.external_size(agents)),
            notice:
              if(warnings == [], do: state.notice, else: Enum.join(Enum.uniq(warnings), "; "))
        }
      else
        state
      end

    evict_inactive_caches(state)
  end

  @doc false
  def load_session_entries(session_id, opts) do
    # Viewing a saved revision must not require permission to resume tool execution.
    case Session.conversation(session_id, :latest, Keyword.take(opts, [:session_dir])) do
      {:ok, %{"messages" => messages}} ->
        messages
        |> Alto.Contrib.ToolDisplay.transcript(
          attachment_directory: Path.join(Session.dir(opts), "attachments")
        )
        |> bounded_entries()

      {:error, reason} ->
        [
          %{
            kind: :system,
            text: "Could not load saved conversation: #{Alto.Contrib.Display.error(reason)}"
          }
        ]
    end
  end

  @doc false
  def load_session_usage(session_id, opts) do
    case Alto.TUI.SavedSession.load(session_id, Keyword.take(opts, [:session_dir])) do
      {:ok, projection} -> projection.usage
      _ -> Usage.new()
    end
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
    do:
      value
      |> Alto.Text.truncate(64_000, "\n[display shortened; see session log]")
      |> Alto.Retained.detach()

  defp bounded_value(value), do: value

  defp touch_cache(state, id),
    do: %{state | cache_order: [id | List.delete(state.cache_order, id)]}

  defp evict_inactive_caches(%__MODULE__{} = state) do
    active = Enum.map(state.runs, fn {_id, run} -> run.task_id end)

    keep =
      MapSet.new([state.selected_task_id || :scratch | active ++ Map.keys(state.input_routes)])

    cached =
      Enum.uniq(Map.keys(state.entries) ++ Map.keys(state.usage) ++ Map.keys(state.subagents))

    order = Enum.uniq(state.cache_order ++ cached) |> Enum.filter(&(&1 in cached))
    inactive = order |> Enum.reverse() |> Enum.reject(&MapSet.member?(keep, &1))
    budget = state.history_cache_bytes
    total = Enum.sum(Map.values(state.entry_bytes)) + Enum.sum(Map.values(state.subagent_bytes))

    {drop, _, _} =
      Enum.reduce_while(inactive, {[], length(cached), total}, fn id, {drop, count, bytes} ->
        if count <= @max_cached_tasks and bytes <= budget,
          do: {:halt, {drop, count, bytes}},
          else:
            {:cont,
             {[id | drop], count - 1,
              bytes - Map.get(state.entry_bytes, id, 0) - Map.get(state.subagent_bytes, id, 0)}}
      end)

    Enum.each(drop, &Alto.TUI.Cache.drop_owner/1)

    %{
      state
      | cache_order: order -- drop,
        entries: Map.drop(state.entries, drop),
        entry_bytes: Map.drop(state.entry_bytes, drop),
        stream_tails: Map.drop(state.stream_tails, drop),
        usage: Map.drop(state.usage, drop),
        subagents: Map.drop(state.subagents, drop),
        subagent_bytes: Map.drop(state.subagent_bytes, drop)
    }
  end

  def sync_backend(state, task) when is_map(task), do: sync_backend(state, task_backend(task))

  def sync_backend(state, backend) when is_atom(backend) do
    state = %{state | selected_backend: backend}

    model =
      with :pass <- Alto.TUI.Backend.ui(state, :sync_model) do
        profile = selected_profile(state)
        profile && profile.default_model
      end

    %{state | selected_model: model} |> restore_model()
  end

  def restore_model(state),
    do: %{
      state
      | selected_model: Preferences.model(state.preferences, state) || state.selected_model
    }

  def remember_selection(state) do
    case Preferences.save(state) do
      {:ok, preferences} ->
        %{state | preferences: preferences}

      {:error, reason} ->
        %{
          state
          | notice:
              "Selection applies now but could not be saved: #{Alto.Contrib.Display.error(reason)}"
        }
    end
  end

  defp status_marker("completed"), do: "✓"
  defp status_marker("failed"), do: "!"
  defp status_marker("waiting"), do: "?"
  defp status_marker(_status), do: "·"
end
