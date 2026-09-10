defmodule Alto.TUI.App do
  @moduledoc "Mouse-aware, multi-project terminal front end for the Alto coding harness."

  use ExRatatui.App

  alias Alto.Approvals.{AllowAll, Delegated, DenyAll}
  alias Alto.Codex.AppServer.Client, as: CodexClient
  alias Alto.Codex.Backend, as: CodexBackend
  alias Alto.Event
  alias Alto.Harness.{Catalog, ProviderProfile, ProviderStore}
  alias Alto.Session
  alias Alto.TUI.{Backend, State, View}
  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}

  @approval_items [
    %{label: "ASK · prompt for each prepared mutation", value: :ask},
    %{label: "READ · deny prepared mutations", value: :read_only},
    %{label: "AUTO · approve prepared mutations", value: :full_access}
  ]

  @codex_approval_items [
    %{label: "ASK · workspace sandbox; prompt for escalations", value: :ask},
    %{label: "READ · read-only sandbox; no escalation", value: :read_only},
    %{label: "AUTO · full host access; no prompts", value: :full_access}
  ]

  @impl true
  def mount(opts) do
    with %Alto.Config{} = config <- Keyword.get(opts, :config),
         {:ok, state} <- State.new(config, opts) do
      dimensions =
        case Keyword.get(opts, :test_mode) do
          {width, height} -> {width, height}
          _other -> terminal_size()
        end

      state = state |> Map.put(:dimensions, dimensions) |> State.ensure_visible_focus()
      if state.selected_backend == :codex, do: send(self(), :ensure_codex_backend)
      {:ok, state}
    else
      nil -> {:error, :tui_config_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def render(state, frame), do: View.widgets(state, frame)

  @impl true
  def handle_event(%Resize{width: width, height: height}, state),
    do:
      {:noreply,
       state
       |> Map.put(:dimensions, {width, height})
       |> State.reconcile_responsive_focus()}

  def handle_event(%Paste{content: content}, %{overlay: nil, focus: :composer} = state) do
    ExRatatui.textarea_insert_str(state.textarea, content)
    {:noreply, state}
  end

  def handle_event(%Paste{content: content}, %{overlay: overlay} = state)
      when not is_nil(overlay) do
    if overlay.kind in [:provider_form, :model_form] do
      {:noreply, insert_form_text(state, content)}
    else
      {:noreply, filter_overlay(state, overlay.filter <> content)}
    end
  end

  def handle_event(%Paste{}, %{details_drawer_open?: true} = state),
    do: {:noreply, state, render?: false}

  def handle_event(%Paste{content: content}, %{type_to_compose?: true} = state) do
    ExRatatui.textarea_insert_str(state.textarea, content)
    {:noreply, %{state | focus: :composer}}
  end

  def handle_event(%Paste{}, state), do: {:noreply, state, render?: false}

  def handle_event(%Mouse{} = mouse, state), do: {:noreply, handle_mouse(state, mouse)}

  def handle_event(%Key{kind: "release"}, state), do: {:noreply, state, render?: false}

  def handle_event(%Key{} = key, %{overlay: overlay} = state) when not is_nil(overlay),
    do: {:noreply, overlay_key(state, key)}

  def handle_event(%Key{code: "esc"}, %{details_drawer_open?: true} = state),
    do: {:noreply, State.close_details_drawer(state)}

  def handle_event(%Key{code: "g", modifiers: ["ctrl"]}, state) do
    {:noreply, %{state | leader?: not state.leader?, notice: nil}}
  end

  def handle_event(%Key{} = key, %{leader?: true} = state) do
    case String.downcase(key.code || "") do
      "a" -> {:noreply, open_overlay(state, :approval)}
      "b" -> {:noreply, open_overlay(state, :backend)}
      "p" -> {:noreply, open_overlay(state, :provider)}
      "m" -> {:noreply, open_overlay(state, :model)}
      "e" -> {:noreply, toggle_composer_mode(state)}
      "w" -> {:noreply, open_overlay(state, :project)}
      "t" -> {:noreply, open_overlay(state, :task)}
      "n" -> {:noreply, state |> State.new_task() |> Map.put(:leader?, false)}
      "d" -> {:noreply, toggle_details(state)}
      "esc" -> {:noreply, %{state | leader?: false, notice: nil}}
      "q" -> {:stop, state}
      _other -> {:noreply, %{state | leader?: false, notice: "unknown gear key"}}
    end
  end

  def handle_event(%Key{code: "f2"}, state), do: {:noreply, open_overlay(state, :approval)}
  def handle_event(%Key{code: "f3"}, state), do: {:noreply, open_overlay(state, :provider)}
  def handle_event(%Key{code: "f4"}, state), do: {:noreply, open_overlay(state, :model)}
  def handle_event(%Key{code: "f5"}, state), do: {:noreply, open_overlay(state, :backend)}
  def handle_event(%Key{code: "f6"}, state), do: {:noreply, toggle_composer_mode(state)}
  def handle_event(%Key{code: "f8"}, state), do: {:noreply, decide_approval(state, :approve)}

  def handle_event(%Key{code: "f9"}, state),
    do: {:noreply, decide_approval(state, {:deny, :user_denied})}

  def handle_event(%Key{code: "tab"}, state), do: {:noreply, State.focus_next(state)}

  def handle_event(%Key{code: "back_tab"}, state),
    do: {:noreply, State.focus_next(state, :previous)}

  def handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state) do
    case active_run(state) do
      nil ->
        {:stop, state}

      {_id, run} ->
        cancel_run(run)
        {:noreply, %{state | notice: "cancelling run…"}}
    end
  end

  def handle_event(%Key{code: "enter", modifiers: modifiers} = key, %{focus: :composer} = state) do
    if "shift" in modifiers do
      forward_textarea(state, key)
    else
      {:noreply, submit(state)}
    end
  end

  def handle_event(%Key{} = key, %{focus: :composer} = state), do: forward_textarea(state, key)

  def handle_event(
        %Key{} = key,
        %{type_to_compose?: true, details_drawer_open?: false} = state
      ) do
    if printable_key?(key) do
      forward_textarea(%{state | focus: :composer}, key)
    else
      {:noreply, navigate(state, key)}
    end
  end

  def handle_event(%Key{} = key, state), do: {:noreply, navigate(state, key)}

  @impl true
  def handle_info({:alto_tui_event, local_id, %Event{} = event, sender, ref}, state) do
    next = ingest_event(state, local_id, event)
    send(sender, {ref, :ok})
    {:noreply, next}
  end

  def handle_info({:alto_tui_event, local_id, %Event{} = event}, state) do
    {:noreply, ingest_event(state, local_id, event)}
  end

  def handle_info({:alto_approval_request, local_id, request, waiter}, state) do
    pending = %{local_id: local_id, request: request, waiter: waiter}

    {:noreply, show_pending_approval(state, pending, "approval required · F8 approve / F9 deny")}
  end

  def handle_info({:alto_models_loaded, profile_id, result}, state) do
    state = %{state | model_loading: MapSet.delete(state.model_loading, profile_id)}

    case result do
      {:ok, models} ->
        state = %{state | models: Map.put(state.models, profile_id, models)}

        state =
          if (state.overlay && state.overlay.kind == :model) and
               state.selected_provider_id == profile_id do
            open_overlay(%{state | overlay: nil}, :model)
          else
            state
          end

        {:noreply, state}

      {:error, reason} ->
        {:noreply, model_error_overlay(state, profile_id, reason)}
    end
  end

  def handle_info(:ensure_codex_backend, state), do: {:noreply, ensure_codex(state, false)}

  def handle_info({:codex_connected, result}, state) do
    case result do
      {:ok, %{client: client, account: account}} ->
        codex = %{state.codex | client: client, status: :ready, account: account}
        next = %{state | codex: codex}

        if CodexBackend.chatgpt_account?(account) do
          {:noreply, refresh_codex(next)}
        else
          {:noreply, codex_account_overlay(next)}
        end

      {:error, reason} ->
        next = put_in(state.codex.status, {:error, reason})
        {:noreply, codex_error_overlay(next, reason)}
    end
  end

  def handle_info({:codex_refreshed, result}, state) do
    case result do
      {:ok, %{models: models, rate_limits: limits}} ->
        selected =
          if state.selected_backend == :codex do
            if Enum.any?(models, &(&1.id == state.selected_model)) do
              state.selected_model
            else
              case Enum.find(models, &Map.get(&1, :default?, false)) || List.first(models) do
                nil -> nil
                model -> model.id
              end
            end
          else
            state.selected_model
          end

        codex = %{state.codex | models: models, rate_limits: limits, status: :ready}
        next = %{state | codex: codex, selected_model: selected, notice: "ChatGPT ready"}

        next =
          if state.overlay && state.overlay.kind in [:codex_account, :codex_connecting],
            do: %{next | overlay: nil},
            else: next

        {:noreply, maybe_load_codex_history(next)}

      {:error, reason} ->
        {:noreply, codex_error_overlay(state, reason)}
    end
  end

  def handle_info({:codex_limits_refreshed, {:ok, limits}}, state),
    do: {:noreply, put_in(state.codex.rate_limits, limits)}

  def handle_info({:codex_limits_refreshed, _error}, state),
    do: {:noreply, state, render?: false}

  def handle_info({:codex_login_started, result}, state) do
    case result do
      {:ok, %{"authUrl" => url, "loginId" => _login_id} = login} ->
        open_codex_url(state, url)

        if CodexBackend.chatgpt_account?(state.codex.account) do
          {:noreply, refresh_codex(state)}
        else
          codex = %{state.codex | login: login, status: :authenticating}

          next = %{
            state
            | codex: codex,
              overlay: codex_login_overlay(login),
              notice: "waiting for ChatGPT sign-in"
          }

          {:noreply, next}
        end

      {:error, reason} ->
        {:noreply, codex_error_overlay(state, reason)}
    end
  end

  def handle_info({:codex_logout_finished, result}, state) do
    case result do
      {:ok, _result} ->
        codex = %{
          state.codex
          | account: nil,
            models: [],
            rate_limits: nil,
            login: nil,
            status: :ready
        }

        {:noreply, codex_account_overlay(%{state | codex: codex, selected_model: nil})}

      {:error, reason} ->
        {:noreply, codex_error_overlay(state, reason)}
    end
  end

  def handle_info({:codex_history_loaded, task_id, result}, state) do
    codex = %{
      state.codex
      | history_loading: MapSet.delete(state.codex.history_loading, task_id)
    }

    state = %{state | codex: codex}

    case result do
      {:ok, entries} ->
        {:noreply, State.put_entries(state, task_id, entries)}

      {:error, reason} ->
        {:noreply, %{state | notice: "could not load Codex history · #{short_inspect(reason)}"}}
    end
  end

  def handle_info({:codex_turn_started, local_id, result}, state) do
    case {Map.get(state.runs, local_id), result} do
      {nil, _result} ->
        {:noreply, state, render?: false}

      {run, {:ok, %{thread_id: thread_id, turn_id: turn_id}}} ->
        run = %{run | thread_id: thread_id, turn_id: turn_id, status: :running}
        state = put_in(state.runs[local_id], run)

        state =
          case Catalog.update_task(
                 run.task_id,
                 %{
                   "status" => "active",
                   "backend" => "codex",
                   "backend_thread_id" => thread_id
                 },
                 state.catalog_opts
               ) do
            {:ok, task} -> State.update_task_record(state, task)
            {:error, _reason} -> state
          end

        codex = %{
          state.codex
          | loaded_threads: MapSet.put(state.codex.loaded_threads, thread_id)
        }

        state = %{state | codex: codex, notice: "Codex working…"}
        state = replay_codex_events(state, run)
        {:noreply, replay_codex_requests(state, run)}

      {run, {:error, reason}} ->
        {:noreply, fail_codex_start(state, local_id, run, reason)}
    end
  end

  def handle_info(
        {:codex_notification, client, method, params},
        %{codex: %{client: client}} = state
      ) do
    {:noreply, ingest_codex_notification(state, method, params)}
  end

  def handle_info(
        {:codex_request, client, id, method, params},
        %{codex: %{client: client}} = state
      ) do
    {:noreply, handle_codex_request(state, id, method, params)}
  end

  def handle_info({:codex_browser_opened, {:error, reason}}, state),
    do:
      {:noreply, %{state | notice: "open the displayed URL manually · #{short_inspect(reason)}"}}

  def handle_info({:codex_browser_opened, _result}, state),
    do: {:noreply, state, render?: false}

  # Alto's async task sends its result directly to the process that started it.
  def handle_info({ref, result}, state) when is_reference(ref) do
    case find_run(state, ref: ref) do
      nil -> {:noreply, state, render?: false}
      {local_id, run} -> {:noreply, finish_run(state, local_id, run, result)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case find_run(state, monitor: monitor) do
      nil ->
        {:noreply, state, render?: false}

      {local_id, run} ->
        next =
          state
          |> State.append_entry(run.task_id, %{
            kind: :error,
            text: "run exited: #{short_inspect(reason)}"
          })
          |> drop_run(local_id)

        {:noreply, %{next | notice: "run failed"}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state, render?: false}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.runs, fn {_id, run} -> cancel_run(run) end)
    :ok
  end

  defp submit(state) do
    prompt = state.textarea |> ExRatatui.textarea_get_value() |> String.trim()

    cond do
      map_size(state.runs) >= 32 ->
        %{state | notice: "too many active runs; finish or cancel one first"}

      prompt == "" ->
        %{state | notice: "write a message first"}

      task_running?(state, state.selected_task_id) ->
        %{state | notice: "this task already has a run in flight"}

      true ->
        submit_backend(state, prompt)
    end
  end

  defp submit_backend(%{selected_backend: :codex} = state, prompt),
    do: submit_codex(state, prompt)

  defp submit_backend(state, prompt) do
    profile = State.selected_profile(state)

    cond do
      state.selected_backend == :alto and is_nil(profile) and
          Alto.Config.provider_mode(state.config) != :none ->
        %{state | notice: "choose a provider before sending"}

      not is_nil(profile) and (is_nil(state.selected_model) or state.selected_model == "") ->
        open_overlay(%{state | notice: "choose a model before sending"}, :model)

      true ->
        with {:ok, state, task} <- ensure_task(state, prompt),
             {:ok, run_options} <- run_options(state, profile),
             {:ok, handle, local_id} <- start_task(task, prompt, run_options) do
          attach_started_run(state, task, prompt, handle, local_id)
        else
          {:error, reason} -> %{state | notice: "cannot start: #{short_inspect(reason)}"}
        end
    end
  end

  defp submit_codex(state, prompt) do
    cond do
      state.codex.status != :ready or is_nil(state.codex.client) ->
        ensure_codex(%{state | notice: "connect ChatGPT before sending"}, true)

      not CodexBackend.chatgpt_account?(state.codex.account) ->
        codex_account_overlay(%{state | notice: "sign in with ChatGPT before sending"})

      is_nil(state.selected_model) or state.selected_model == "" ->
        open_overlay(%{state | notice: "choose a Codex model before sending"}, :model)

      true ->
        with {:ok, state, task} <- ensure_task(state, prompt) do
          start_codex_task(state, task, prompt)
        else
          {:error, reason} -> %{state | notice: "cannot start: #{short_inspect(reason)}"}
        end
    end
  end

  defp start_codex_task(state, task, prompt) do
    local_id = "codex-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    owner = self()
    client = state.codex.client
    project = State.selected_project(state)

    opts = [
      cwd: project["root"],
      model: state.selected_model,
      approval: state.approval_level
    ]

    run = %{
      kind: :codex,
      client: client,
      task_id: task["id"],
      thread_id: task["backend_thread_id"],
      turn_id: nil,
      status: :starting,
      approval_level: state.approval_level,
      started_at_ms: System.system_time(:millisecond)
    }

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      result = CodexBackend.start_turn(client, task["backend_thread_id"], prompt, opts)
      send(owner, {:codex_turn_started, local_id, result})
    end)

    ExRatatui.textarea_set_value(state.textarea, "")

    state =
      case Catalog.update_task(
             task["id"],
             %{"status" => "active", "backend" => "codex"},
             state.catalog_opts
           ) do
        {:ok, updated} -> State.update_task_record(state, updated)
        {:error, _reason} -> state
      end

    state
    |> State.append_entry(task["id"], %{kind: :user, text: prompt})
    |> Map.update!(:runs, &Map.put(&1, local_id, run))
    |> Map.put(:notice, "starting Codex…")
    |> Map.put(:transcript_scroll, 0)
    |> Map.put(:transcript_follow?, true)
  end

  # The event sink must know its correlation id before Alto starts.
  defp deliver_event(owner, id, event) do
    ref = make_ref()
    send(owner, {:alto_tui_event, id, event, self(), ref})

    receive do
      {^ref, :ok} -> :ok
    after
      1_000 -> :display_unavailable
    end
  end

  defp start_task(task, prompt, run_options) do
    local_id = "tui-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    owner = self()

    run_options =
      run_options
      |> Keyword.put(:event_sink, &deliver_event(owner, local_id, &1))
      |> Keyword.update(
        :tool_context_metadata,
        %{approval_sink: owner},
        &Map.put(&1, :approval_sink, owner)
      )

    with {:ok, handle} <- do_start_task(task, prompt, run_options) do
      {:ok, handle, local_id}
    end
  end

  defp attach_started_run(state, task, prompt, handle, local_id) do
    monitor = handle.task.ref

    run = %{
      kind: :alto,
      adapter: Backend.lookup(state.run_options, state.selected_backend),
      handle: handle,
      task_id: task["id"],
      ref: handle.task.ref,
      monitor: monitor,
      started_at_ms: System.system_time(:millisecond)
    }

    ExRatatui.textarea_set_value(state.textarea, "")

    state =
      case Catalog.update_task(task["id"], %{"status" => "active"}, state.catalog_opts) do
        {:ok, updated} -> State.update_task_record(state, updated)
        {:error, _reason} -> state
      end

    state
    |> State.append_entry(task["id"], %{kind: :user, text: prompt})
    |> Map.update!(:runs, &Map.put(&1, local_id, run))
    |> Map.put(:notice, "run started")
    |> Map.put(:transcript_scroll, 0)
    |> Map.put(:transcript_follow?, true)
  end

  defp do_start_task(task, prompt, run_options) do
    backend = State.task_backend(task)

    if backend == :alto do
      start_native_task(task, prompt, run_options)
    else
      with {:ok, module, options} <- Backend.lookup(run_options, backend),
           {:ok, %Alto.Runner.Serial.Handle{} = handle} <-
             module.start(task, prompt, run_options, options),
           do: {:ok, handle}
    end
  end

  defp start_native_task(task, prompt, run_options) do
    case task["session_id"] do
      session_id when is_binary(session_id) ->
        session_opts = Keyword.take(run_options, [:session_dir])

        with {:ok, snapshot} <- Session.transcript(session_id, session_opts) do
          run_options =
            run_options
            |> Keyword.put(:session, session_id)
            |> Keyword.put(:resume, %{
              messages: snapshot.messages,
              transcript_bytes: snapshot.transcript_bytes,
              revision: snapshot.revision
            })

          Alto.start(prompt, run_options)
        end

      _none ->
        Alto.start(prompt, Keyword.put(run_options, :session, :new))
    end
  end

  defp ensure_task(%{selected_task_id: nil} = state, prompt) do
    title = prompt |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 96)

    opts = Keyword.put(state.catalog_opts, :backend, Atom.to_string(state.selected_backend))

    case Catalog.create_task(state.selected_project_id, title, opts) do
      {:ok, task} -> {:ok, State.put_task(state, task), task}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_task(state, _prompt), do: {:ok, state, State.selected_task(state)}

  defp run_options(state, profile) do
    project = State.selected_project(state)

    if project do
      approval = configured_or_ui_approval(state)

      opts =
        state.run_options
        |> Keyword.drop([
          :provider_profiles,
          :codex_backend,
          :tui,
          :listeners,
          :queue,
          :runs,
          :sessions
        ])
        |> Keyword.put(:approval, approval)
        |> Keyword.put(:cwd, project["root"])

      opts =
        case profile do
          nil -> Keyword.put(opts, :provider, nil)
          profile -> Keyword.put(opts, :provider, runtime_provider(state, profile))
        end

      {:ok, opts}
    else
      {:error, :project_required}
    end
  end

  defp configured_or_ui_approval(state) do
    case Keyword.fetch(state.run_options, :approval) do
      {:ok, Alto.Approvals.Interactive} ->
        {Delegated, sink: self()}

      {:ok, {Alto.Approvals.Interactive, []}} ->
        {Delegated, sink: self()}

      {:ok, configured} ->
        configured

      :error ->
        case state.approval_level do
          :ask -> {Delegated, sink: self()}
          :read_only -> {DenyAll, reason: :read_only_mode}
          :full_access -> AllowAll
        end
    end
  end

  defp runtime_provider(state, profile) do
    {module, options} =
      ProviderProfile.runtime_provider(profile, state.selected_model,
        credentials_path: state.credentials_path
      )

    {module, maybe_context_window(options, selected_model_metadata(state, profile))}
  end

  defp selected_model_metadata(state, profile) do
    state.models
    |> Map.get(profile.id, profile.models)
    |> case do
      models when is_list(models) ->
        Enum.find(models, &model_id_matches?(&1, state.selected_model))

      _other ->
        nil
    end
  end

  defp model_id_matches?(%{id: id}, selected), do: id == selected
  defp model_id_matches?(%{"id" => id}, selected), do: id == selected
  defp model_id_matches?(_, _), do: false

  defp maybe_context_window(options, %{context_window: value})
       when is_integer(value) and value > 0,
       do: Keyword.put_new(options, :context_window, value)

  defp maybe_context_window(options, %{context_length: value})
       when is_integer(value) and value > 0,
       do: Keyword.put_new(options, :context_window, value)

  defp maybe_context_window(options, _metadata), do: options

  defp finish_run(state, local_id, run, result) do
    {status, session_id, entry, notice, persistence} =
      case result do
        {:ok, completed} ->
          {"completed", completed.session_id, nil, "run completed", completed.persistence}

        {:error, reason, completed} ->
          {"failed", completed.session_id, %{kind: :error, text: short_inspect(reason)},
           "run failed", completed.persistence}

        other ->
          {"failed", nil, %{kind: :error, text: short_inspect(other)}, "run failed", nil}
      end

    {entry, notice} = persistence_feedback(entry, notice, persistence)

    changes = %{"status" => status, "session_id" => session_id}

    state =
      case Catalog.update_task(run.task_id, changes, state.catalog_opts) do
        {:ok, task} -> State.update_task_record(state, task)
        {:error, _reason} -> state
      end

    state = if entry, do: State.append_entry(state, run.task_id, entry), else: state

    state
    |> drop_run(local_id)
    |> Map.put(:notice, notice)
  end

  defp persistence_feedback(entry, notice, {:degraded, errors}) do
    warning = %{kind: :error, text: "persistence degraded", detail: short_inspect(errors)}
    {entry || warning, notice <> " · persistence degraded"}
  end

  defp persistence_feedback(entry, notice, _status), do: {entry, notice}

  defp ingest_event(state, local_id, %Event{} = event) do
    case Map.get(state.runs, local_id) do
      nil -> state
      run -> do_ingest_event(state, run.task_id, event)
    end
  end

  defp do_ingest_event(state, task_id, %Event{type: :model_delta, data: %{text: text}}),
    do: State.append_assistant_delta(state, task_id, text)

  defp do_ingest_event(state, task_id, %Event{type: :model_completed, data: data}) do
    State.update_usage(state, task_id, Map.get(data, :usage, %{}))
  end

  defp do_ingest_event(state, task_id, %Event{type: :tool_started, data: data}) do
    State.append_entry(state, task_id, %{kind: :tool, text: "#{data.name} …"})
  end

  defp do_ingest_event(state, task_id, %Event{type: :tool_completed, data: data}) do
    State.append_entry(state, task_id, %{
      kind: :tool,
      text: "#{data.name} ✓",
      detail: Map.get(data, :output)
    })
  end

  defp do_ingest_event(state, task_id, %Event{type: :tool_failed, data: data}) do
    detail = short_inspect(data.error)

    State.append_entry(state, task_id, %{
      kind: :error,
      text: "#{data.name} failed",
      detail: detail
    })
  end

  defp do_ingest_event(state, task_id, %Event{type: :context_handoff_created, data: data}) do
    files = data |> Map.get(:files, %{}) |> Map.values() |> Enum.join(" · ")
    next = Map.get(data, :next_step, "")

    State.append_entry(state, task_id, %{
      kind: :system,
      text: "handoff created\n#{files}\nnext: #{next}"
    })
  end

  defp do_ingest_event(state, task_id, %Event{type: :subagent_completed, data: data}) do
    State.append_entry(state, task_id, %{kind: :system, text: "subagent #{data.id} completed"})
  end

  defp do_ingest_event(state, _task_id, _event), do: state

  defp open_overlay(state, kind) do
    state = %{state | leader?: false, notice: nil}

    case overlay_items(state, kind) do
      {:codex_account} ->
        if state.codex.status in [:ready, :authenticating],
          do: codex_account_overlay(state),
          else: ensure_codex(state, true)

      {:codex_connect} ->
        ensure_codex(state, true)

      {:load, profile} ->
        owner = self()

        Task.start(fn ->
          send(
            owner,
            {:alto_models_loaded, profile.id,
             ProviderProfile.models(profile, credentials_path: state.credentials_path)}
          )
        end)

        overlay = %{
          kind: :model,
          title: "models · loading #{profile.label}…",
          index: 0,
          filter: "",
          all_items: [%{label: "Loading model catalog…", value: nil}],
          items: [%{label: "Loading model catalog…", value: nil}]
        }

        %{state | overlay: overlay, model_loading: MapSet.put(state.model_loading, profile.id)}

      {:ok, title, items, selected} ->
        index = Enum.find_index(items, &(&1.value == selected)) || 0

        %{
          state
          | overlay: %{
              kind: kind,
              title: title,
              index: index,
              filter: "",
              all_items: items,
              items: items
            }
        }

      {:error, reason} ->
        %{state | notice: reason}
    end
  end

  defp overlay_items(%{selected_backend: :codex} = state, :approval),
    do: {:ok, "Codex approval and sandbox level", @codex_approval_items, state.approval_level}

  defp overlay_items(state, :approval),
    do: {:ok, "approval level", @approval_items, state.approval_level}

  defp overlay_items(state, :backend) do
    items = Backend.items(state.run_options)

    {:ok, "execution backend", items, state.selected_backend}
  end

  defp overlay_items(%{selected_backend: :codex}, :provider), do: {:codex_account}

  defp overlay_items(state, :provider) do
    setup = [
      %{label: "＋ Add OpenAI-compatible provider…", value: {:configure_provider, nil}}
    ]

    configure =
      case State.selected_profile(state) do
        %{module: Alto.Providers.OpenAICompatible} = profile ->
          [%{label: "⚙ Configure #{profile.label}…", value: {:configure_provider, profile.id}}]

        _other ->
          []
      end

    profiles =
      Enum.map(state.profiles, &%{label: &1.label <> " · " <> &1.id, value: &1.id})

    {:ok, "providers · select or configure", setup ++ configure ++ profiles,
     state.selected_provider_id}
  end

  defp overlay_items(%{selected_backend: :codex} = state, :model) do
    case state.codex do
      %{status: :ready, models: [_ | _] = models} ->
        items = Enum.map(models, &%{label: model_label(&1), value: model_id(&1)})
        {:ok, "Codex models · type to filter", items, state.selected_model}

      _other ->
        {:codex_connect}
    end
  end

  defp overlay_items(state, :model) do
    case State.selected_profile(state) do
      nil ->
        {:error, "choose a provider first"}

      profile ->
        case Map.fetch(state.models, profile.id) do
          {:ok, models} ->
            items = Enum.map(models, &%{label: model_label(&1), value: model_id(&1)})
            {:ok, "models · type to filter", items, state.selected_model}

          :error ->
            if MapSet.member?(state.model_loading, profile.id),
              do: {:error, "models are already loading"},
              else: {:load, profile}
        end
    end
  end

  defp overlay_items(state, :project) do
    items =
      Enum.map(state.projects, &%{label: &1["name"] <> " · " <> &1["root"], value: &1["id"]})

    {:ok, "workspaces · type to filter", items, state.selected_project_id}
  end

  defp overlay_items(state, :task) do
    items =
      state.tasks
      |> Map.get(state.selected_project_id, [])
      |> Enum.map(&%{label: &1["status"] <> " · " <> &1["title"], value: &1["id"]})

    if items == [],
      do: {:error, "no tasks in this workspace"},
      else: {:ok, "tasks · type to filter", items, state.selected_task_id}
  end

  defp overlay_key(%{overlay: %{kind: :provider_form}} = state, key),
    do: provider_form_key(state, key)

  defp overlay_key(%{overlay: %{kind: :model_form}} = state, key),
    do: model_form_key(state, key)

  defp overlay_key(state, %Key{code: "esc"}), do: %{state | overlay: nil}

  defp overlay_key(state, %Key{code: code}) when code in ["up", "k"],
    do: move_overlay(state, -1)

  defp overlay_key(state, %Key{code: code}) when code in ["down", "j"],
    do: move_overlay(state, 1)

  defp overlay_key(state, %Key{code: "enter"}), do: select_overlay(state)

  defp overlay_key(state, %Key{code: "backspace"}) do
    filter =
      String.slice(state.overlay.filter, 0, max(String.length(state.overlay.filter) - 1, 0))

    filter_overlay(state, filter)
  end

  defp overlay_key(state, %Key{code: code, modifiers: modifiers})
       when is_binary(code) and byte_size(code) > 0 do
    if modifiers == [] and String.printable?(code) and String.length(code) == 1 do
      filter_overlay(state, state.overlay.filter <> code)
    else
      state
    end
  end

  defp overlay_key(state, _key), do: state

  defp filter_overlay(state, filter) do
    normalized = String.downcase(filter)

    items =
      Enum.filter(
        state.overlay.all_items,
        &String.contains?(String.downcase(&1.label), normalized)
      )

    title = state.overlay.title |> String.split(" · filter:", parts: 2) |> hd()
    title = if filter == "", do: title, else: title <> " · filter: " <> filter
    %{state | overlay: %{state.overlay | filter: filter, items: items, index: 0, title: title}}
  end

  defp move_overlay(%{overlay: %{items: []}} = state, _delta), do: state

  defp move_overlay(state, delta) do
    count = length(state.overlay.items)
    index = rem(state.overlay.index + delta + count, count)
    %{state | overlay: %{state.overlay | index: index}}
  end

  defp select_overlay(%{overlay: %{items: items, index: index}} = state) do
    case Enum.at(items, index) do
      nil -> state
      %{value: nil} -> state
      %{value: {:configure_provider, profile_id}} -> open_provider_form(state, profile_id)
      %{value: {:retry_models, profile_id}} -> retry_models(state, profile_id)
      %{value: {:enter_model, profile_id}} -> open_model_form(state, profile_id)
      %{value: :codex_login} -> start_codex_login(state)
      %{value: :codex_refresh} -> refresh_codex(state)
      %{value: :codex_reconnect} -> reconnect_codex(state)
      %{value: :codex_logout} -> logout_codex(state)
      %{value: {:codex_open_url, url}} -> open_codex_url(state, url)
      %{value: {:codex_cancel_login, login_id}} -> cancel_codex_login(state, login_id)
      %{value: backend} when backend in [:alto, :codex] -> select_backend(state, backend)
      %{value: value} -> apply_selection(state, state.overlay.kind, value)
    end
  end

  defp apply_selection(state, :backend, value), do: select_backend(state, value)

  defp apply_selection(state, :approval, value),
    do: %{state | approval_level: value, overlay: nil, notice: "approval level: #{value}"}

  defp apply_selection(state, :provider, value) do
    profile = Enum.find(state.profiles, &(&1.id == value))

    %{
      state
      | selected_provider_id: value,
        selected_model: profile.default_model,
        overlay: nil,
        notice: "provider: #{profile.label}"
    }
  end

  defp apply_selection(state, :model_error, value), do: apply_selection(state, :model, value)

  defp apply_selection(state, :codex_error, value), do: apply_selection(state, :model, value)

  defp apply_selection(state, :model, value),
    do: %{state | selected_model: value, overlay: nil, notice: "model: #{value}"}

  defp apply_selection(state, :project, value),
    do:
      state
      |> State.select_project(value)
      |> prepare_selected_backend()
      |> Map.put(:overlay, nil)
      |> Map.put(:notice, "workspace switched")

  defp apply_selection(state, :task, value),
    do:
      state
      |> State.select_task(value)
      |> prepare_selected_backend()
      |> Map.put(:overlay, nil)
      |> Map.put(:notice, "task switched")

  defp handle_mouse(state, %Mouse{kind: "down", button: "left", x: x, y: y}) do
    {width, height} = state.dimensions

    case View.hit_target(state, width, height, x, y) do
      :left_seam ->
        %{state | dragging: :left_seam}

      :right_seam ->
        %{state | dragging: :right_seam}

      {:rail_row, row} ->
        state
        |> State.select_rail_row(row)
        |> prepare_selected_backend()
        |> Map.put(:focus, :rail)

      {:setting, :entry_mode} ->
        toggle_composer_mode(state)

      {:setting, :details} ->
        toggle_details(state)

      {:setting, kind} ->
        open_overlay(state, kind)

      :composer ->
        %{state | focus: :composer}

      :transcript ->
        %{state | focus: :transcript}

      :details ->
        %{state | focus: :details}

      :details_close ->
        State.close_details_drawer(state)

      :details_drawer_outside ->
        State.close_details_drawer(state)

      {:approval, decision} ->
        decide_approval(state, approval_decision(decision))

      {:overlay_row, row} ->
        handle_overlay_click(state, row)

      :overlay_outside ->
        %{state | overlay: nil}

      _other ->
        state
    end
  end

  defp handle_mouse(state, %Mouse{kind: "drag", x: x}) do
    {width, _height} = state.dimensions

    case state.dragging do
      :left_seam -> %{state | rail_width: (x + 1) |> max(20) |> min(48)}
      :right_seam -> %{state | details_width: (width - x) |> max(28) |> min(60)}
      _other -> state
    end
  end

  defp handle_mouse(state, %Mouse{kind: "up"}), do: %{state | dragging: nil}

  defp handle_mouse(state, %Mouse{kind: kind, x: x, y: y})
       when kind in ["scroll_up", "scroll_down"] do
    {width, height} = state.dimensions
    delta = if kind == "scroll_up", do: -3, else: 3

    case View.hit_target(state, width, height, x, y) do
      :transcript -> scroll_transcript(state, delta)
      :details -> %{state | details_scroll: max(state.details_scroll + delta, 0)}
      _other -> state
    end
  end

  defp handle_mouse(state, _mouse), do: state

  defp navigate(state, %Key{code: code}) when code in ["down", "j"] do
    case state.focus do
      :rail -> move_rail(state, 1)
      :transcript -> scroll_transcript(state, 1)
      :details -> %{state | details_scroll: state.details_scroll + 1}
      _other -> state
    end
  end

  defp navigate(state, %Key{code: code}) when code in ["up", "k"] do
    case state.focus do
      :rail -> move_rail(state, -1)
      :transcript -> scroll_transcript(state, -1)
      :details -> %{state | details_scroll: max(state.details_scroll - 1, 0)}
      _other -> state
    end
  end

  defp navigate(state, %Key{code: "g"}) when state.focus == :transcript,
    do: %{state | transcript_scroll: 0, transcript_follow?: false}

  defp navigate(state, %Key{code: "G"}) when state.focus == :transcript,
    do: %{state | transcript_follow?: true}

  defp navigate(state, %Key{code: "h"}), do: State.focus_next(state, :previous)
  defp navigate(state, %Key{code: "l"}), do: State.focus_next(state)

  defp navigate(state, _key), do: state

  defp printable_key?(%Key{code: code, modifiers: modifiers}) when is_binary(code) do
    String.length(code) == 1 and Enum.all?(modifiers, &(&1 == "shift"))
  end

  defp printable_key?(_key), do: false

  defp toggle_details(state) do
    state = %{state | leader?: false}

    cond do
      state.details_drawer_open? ->
        State.close_details_drawer(state)

      State.details_pane_visible?(state) ->
        state
        |> Map.put(:details_visible?, false)
        |> State.ensure_visible_focus()

      true ->
        requested = %{state | details_visible?: true}

        if State.details_pane_visible?(requested) do
          %{requested | focus: :details}
        else
          State.open_details_drawer(requested)
        end
    end
  end

  defp move_rail(state, delta) do
    rows = State.rail_rows(state)
    target = state.selected_task_id || state.selected_project_id
    current = Enum.find_index(rows, &(&1.id == target)) || 0
    index = (current + delta) |> max(0) |> min(max(length(rows) - 1, 0))
    state |> State.select_rail_row(index) |> prepare_selected_backend()
  end

  defp scroll_transcript(state, delta) do
    bottom = View.transcript_bottom_scroll(state)
    current = if state.transcript_follow?, do: bottom, else: state.transcript_scroll
    next = (current + delta) |> max(0) |> min(bottom)
    %{state | transcript_scroll: next, transcript_follow?: next == bottom}
  end

  defp forward_textarea(state, key) do
    ExRatatui.textarea_handle_key(state.textarea, key.code, key.modifiers)
    {:noreply, state}
  end

  defp toggle_composer_mode(%{composer_mode: :prose} = state) do
    %{state | composer_mode: :code, leader?: false, notice: "entry mode: code · wrapping off"}
  end

  defp toggle_composer_mode(state) do
    %{state | composer_mode: :prose, leader?: false, notice: "entry mode: prose · wrapping on"}
  end

  defp decide_approval(%{pending_approvals: []} = state, _decision),
    do: %{state | notice: "no pending approval"}

  defp decide_approval(%{pending_approvals: [pending | rest]} = state, decision) do
    case pending do
      %{
        backend: :codex,
        client: client,
        request_id: request_id,
        method: method,
        params: params
      } ->
        CodexClient.respond(
          client,
          request_id,
          codex_approval_response(method, decision, params)
        )

      %{waiter: waiter, request: request} ->
        send(waiter, {:alto_approval_decision, request.id, decision})
    end

    next = %{state | pending_approvals: rest, notice: approval_notice(decision)}

    cond do
      rest != [] and next.details_drawer_open? ->
        %{next | focus: :details}

      rest == [] and next.details_drawer_auto_opened? ->
        State.close_details_drawer(next)

      next.details_drawer_open? ->
        %{next | focus: :details}

      true ->
        %{next | focus: :composer}
    end
  end

  defp show_pending_approval(state, pending, notice) do
    next = %{
      state
      | pending_approvals: state.pending_approvals ++ [pending],
        details_visible?: true,
        notice: notice
    }

    cond do
      not next.approval_auto_open? ->
        State.ensure_visible_focus(next)

      State.details_pane_visible?(next) ->
        %{next | focus: :details}

      next.details_drawer_open? ->
        %{next | focus: :details}

      true ->
        State.open_details_drawer(next, auto: true)
    end
  end

  defp approval_decision(:approve), do: :approve
  defp approval_decision(:deny), do: {:deny, :user_denied}
  defp approval_notice(:approve), do: "approved"
  defp approval_notice({:deny, _reason}), do: "denied"

  defp task_running?(_state, nil), do: false

  defp task_running?(state, task_id),
    do: Enum.any?(state.runs, fn {_id, run} -> run.task_id == task_id end)

  defp active_run(state),
    do: Enum.find(state.runs, fn {_id, run} -> run.task_id == state.selected_task_id end)

  defp cancel_run(%{adapter: {:ok, module, opts}, handle: handle}),
    do: module.cancel(handle, :user, opts)

  defp cancel_run(%{kind: :alto, handle: handle}), do: Alto.cancel(handle, :user)

  defp cancel_run(%{kind: :codex, client: client, thread_id: thread_id, turn_id: turn_id})
       when is_binary(thread_id) and is_binary(turn_id),
       do: CodexClient.interrupt_turn(client, thread_id, turn_id)

  defp cancel_run(_run), do: :ok

  defp find_run(state, matcher) do
    Enum.find(state.runs, fn {_id, run} ->
      Enum.all?(matcher, fn {key, value} -> run[key] == value end)
    end)
  end

  defp drop_run(state, local_id), do: %{state | runs: Map.delete(state.runs, local_id)}

  defp put_overlay_index(state, row) do
    index = row |> max(0) |> min(max(length(state.overlay.items) - 1, 0))
    %{state | overlay: %{state.overlay | index: index}}
  end

  defp model_error_overlay(state, profile_id, reason) do
    profile = Enum.find(state.profiles, &(&1.id == profile_id))

    configure =
      if profile && profile.module == Alto.Providers.OpenAICompatible do
        [
          %{
            label: "Configure #{profile.label} credentials…",
            value: {:configure_provider, profile_id}
          }
        ]
      else
        []
      end

    items =
      configure ++
        [
          %{label: "Retry model catalog", value: {:retry_models, profile_id}},
          %{label: "Enter an exact model ID…", value: {:enter_model, profile_id}}
        ]

    message =
      reason
      |> short_inspect()
      |> redact_secrets()
      |> String.replace(~r/\s+/, " ")
      |> String.slice(0, 240)

    %{
      state
      | overlay: %{
          kind: :model_error,
          title: "model catalog unavailable",
          message: message,
          index: 0,
          filter: "",
          all_items: items,
          items: items
        },
        notice: "model catalog needs attention"
    }
  end

  defp retry_models(state, profile_id) do
    case Enum.find(state.profiles, &(&1.id == profile_id)) do
      nil ->
        %{state | overlay: nil, notice: "provider is no longer available"}

      _profile ->
        open_overlay(%{state | selected_provider_id: profile_id, overlay: nil}, :model)
    end
  end

  defp open_provider_form(state, profile_id) do
    profile = Enum.find(state.profiles, &(&1.id == profile_id))
    new? = is_nil(profile)

    defaults = %{
      id: (profile && profile.id) || "",
      label: (profile && profile.label) || "",
      base_url: (profile && Keyword.get(profile.options, :base_url)) || "",
      api_key: "",
      model: (profile && profile.default_model) || ""
    }

    fields =
      Enum.map([:id, :label, :base_url, :api_key, :model], fn key ->
        input = ExRatatui.text_input_new()
        ExRatatui.text_input_set_value(input, Map.fetch!(defaults, key))
        %{key: key, input: input, locked?: key == :id and not new?}
      end)

    stored? = profile && ProviderStore.api_key_saved?(profile, credentials_opts(state))

    %{
      state
      | overlay: %{
          kind: :provider_form,
          title: if(new?, do: "add provider", else: "configure #{profile.label}"),
          fields: fields,
          field_index: if(new?, do: 0, else: 3),
          existing_id: profile_id,
          key_saved?: stored? == true,
          error: nil,
          after_save:
            if(state.overlay && state.overlay.kind == :model_error, do: :model, else: nil)
        },
        notice: nil
    }
  end

  defp open_model_form(state, profile_id) do
    input = ExRatatui.text_input_new()

    %{
      state
      | selected_provider_id: profile_id,
        overlay: %{
          kind: :model_form,
          title: "exact model ID",
          input: input,
          profile_id: profile_id,
          error: nil
        }
    }
  end

  defp provider_form_key(state, %Key{code: "esc"}), do: %{state | overlay: nil}

  defp provider_form_key(state, %Key{code: "s", modifiers: modifiers}) do
    if "ctrl" in modifiers, do: save_provider_form(state), else: edit_provider_field(state, "s")
  end

  defp provider_form_key(state, %Key{code: code}) when code in ["tab", "down"] do
    move_form_field(state, 1)
  end

  defp provider_form_key(state, %Key{code: code}) when code in ["back_tab", "up"] do
    move_form_field(state, -1)
  end

  defp provider_form_key(state, %Key{code: "enter"}) do
    if state.overlay.field_index == length(state.overlay.fields) - 1,
      do: save_provider_form(state),
      else: move_form_field(state, 1)
  end

  defp provider_form_key(state, %Key{code: code, modifiers: modifiers}) do
    if modifiers == [] or code in ["backspace", "delete", "left", "right", "home", "end"] do
      edit_provider_field(state, code)
    else
      state
    end
  end

  defp model_form_key(state, %Key{code: "esc"}), do: %{state | overlay: nil}

  defp model_form_key(state, %Key{code: "enter"}) do
    model = state.overlay.input |> ExRatatui.text_input_get_value() |> String.trim()

    if model == "" do
      put_in(state.overlay.error, "model ID is required")
    else
      %{state | selected_model: model, overlay: nil, notice: "model: #{model}"}
    end
  end

  defp model_form_key(state, %Key{code: code, modifiers: modifiers}) do
    if modifiers == [] or code in ["backspace", "delete", "left", "right", "home", "end"] do
      ExRatatui.text_input_handle_key(state.overlay.input, code)
    end

    state
  end

  defp move_form_field(state, delta) do
    count = length(state.overlay.fields)
    index = rem(state.overlay.field_index + delta + count, count)
    put_in(state.overlay.field_index, index)
  end

  defp edit_provider_field(state, code) do
    field = Enum.at(state.overlay.fields, state.overlay.field_index)

    unless field.locked? do
      ExRatatui.text_input_handle_key(field.input, code)
    end

    put_in(state.overlay.error, nil)
  end

  defp insert_form_text(%{overlay: %{kind: :provider_form}} = state, content) do
    field = Enum.at(state.overlay.fields, state.overlay.field_index)
    unless field.locked?, do: ExRatatui.text_input_insert_str(field.input, content)
    put_in(state.overlay.error, nil)
  end

  defp insert_form_text(%{overlay: %{kind: :model_form}} = state, content) do
    ExRatatui.text_input_insert_str(state.overlay.input, content)
    put_in(state.overlay.error, nil)
  end

  defp save_provider_form(state) do
    attrs =
      Map.new(state.overlay.fields, fn field ->
        {field.key, ExRatatui.text_input_get_value(field.input)}
      end)

    api_key_field = Enum.find(state.overlay.fields, &(&1.key == :api_key))

    case ProviderStore.save(attrs, credentials_opts(state)) do
      {:ok, profile} ->
        # Clear the opaque native input before releasing the form reference.
        ExRatatui.text_input_set_value(api_key_field.input, "")

        prior = Enum.find(state.profiles, &(&1.id == profile.id))
        profile = merge_saved_profile(prior, profile)

        profiles =
          [profile | Enum.reject(state.profiles, &(&1.id == profile.id))]
          |> Enum.sort_by(&String.downcase(&1.label))

        next = %{
          state
          | profiles: profiles,
            selected_provider_id: profile.id,
            selected_model: profile.default_model,
            models: Map.delete(state.models, profile.id),
            overlay: nil,
            notice: "provider saved"
        }

        if state.overlay.after_save == :model, do: open_overlay(next, :model), else: next

      {:error, reason} ->
        put_in(state.overlay.error, human_provider_error(reason))
    end
  end

  defp handle_overlay_click(%{overlay: %{kind: :provider_form}} = state, row) do
    cond do
      row in 2..6 -> put_in(state.overlay.field_index, row - 2)
      row == 8 -> save_provider_form(state)
      row == 9 -> %{state | overlay: nil}
      true -> state
    end
  end

  defp handle_overlay_click(%{overlay: %{kind: :model_form}} = state, row) do
    cond do
      row == 5 -> model_form_key(state, %Key{code: "enter"})
      row == 6 -> %{state | overlay: nil}
      true -> state
    end
  end

  defp handle_overlay_click(state, row),
    do: state |> put_overlay_index(row - overlay_list_offset(state.overlay)) |> select_overlay()

  defp overlay_list_offset(%{message: message}) when is_binary(message), do: 3
  defp overlay_list_offset(_overlay), do: 0

  defp select_backend(state, backend) when is_atom(backend) do
    task = State.selected_task(state)

    cond do
      backend not in Enum.map(Backend.items(state.run_options), & &1.value) ->
        %{state | notice: "backend is not configured"}

      state.selected_backend == backend ->
        if backend == :codex,
          do: ensure_codex(%{state | overlay: nil}, true),
          else: %{state | overlay: nil}

      task_running?(state, state.selected_task_id) ->
        %{state | overlay: nil, notice: "finish or cancel this run before switching backend"}

      task_backend_locked?(task) ->
        %{
          state
          | overlay: nil,
            notice: "this task is already bound to #{State.task_backend(task)}"
        }

      true ->
        state = persist_task_backend(state, task, backend)
        model = backend_model(state, backend)
        next = %{state | selected_backend: backend, selected_model: model, overlay: nil}

        if backend == :codex,
          do: ensure_codex(next, true),
          else: %{next | notice: "backend: #{backend}"}
    end
  end

  defp task_backend_locked?(nil), do: false

  defp task_backend_locked?(task),
    do: is_binary(task["session_id"]) or is_binary(task["backend_thread_id"])

  defp persist_task_backend(state, nil, _backend), do: state

  defp persist_task_backend(state, task, backend) do
    case Catalog.update_task(
           task["id"],
           %{"backend" => Atom.to_string(backend)},
           state.catalog_opts
         ) do
      {:ok, updated} -> State.update_task_record(state, updated)
      {:error, _reason} -> state
    end
  end

  defp backend_model(state, :alto) do
    case State.selected_profile(state) do
      nil -> nil
      profile -> profile.default_model
    end
  end

  defp backend_model(state, :codex) do
    Keyword.get(state.codex.options, :model) ||
      case Enum.find(state.codex.models, &Map.get(&1, :default?, false)) ||
             List.first(state.codex.models) do
        nil -> nil
        model -> model.id
      end
  end

  defp backend_model(state, _custom) do
    profile = State.selected_profile(state)
    profile && profile.default_model
  end

  defp prepare_selected_backend(%{selected_backend: :codex} = state) do
    if state.codex.status == :ready and is_pid(state.codex.client),
      do: maybe_load_codex_history(state),
      else: ensure_codex(state, false)
  end

  defp prepare_selected_backend(state), do: state

  defp maybe_load_codex_history(%{selected_backend: :codex} = state) do
    task = State.selected_task(state)
    task_id = task && task["id"]
    thread_id = task && task["backend_thread_id"]
    entries = Map.get(state.entries, task_id, [])

    cond do
      not is_binary(thread_id) ->
        state

      entries != [] ->
        state

      MapSet.member?(state.codex.history_loading, task_id) ->
        state

      not is_pid(state.codex.client) ->
        state

      true ->
        owner = self()
        client = state.codex.client

        Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
          send(owner, {:codex_history_loaded, task_id, CodexBackend.history(client, thread_id)})
        end)

        put_in(state.codex.history_loading, MapSet.put(state.codex.history_loading, task_id))
    end
  end

  defp maybe_load_codex_history(state), do: state

  defp ensure_codex(state, show_overlay?) do
    cond do
      state.codex.status == :ready and is_pid(state.codex.client) and
          Process.alive?(state.codex.client) ->
        if show_overlay?, do: codex_account_overlay(state), else: state

      state.codex.status == :authenticating and is_map(state.codex.login) ->
        if show_overlay?,
          do: %{state | overlay: codex_login_overlay(state.codex.login)},
          else: state

      state.codex.status == :connecting ->
        if show_overlay?, do: %{state | overlay: codex_connecting_overlay()}, else: state

      state.codex.status == :refreshing and is_pid(state.codex.client) ->
        if show_overlay?,
          do: %{state | overlay: codex_connecting_overlay("refreshing models and quota…")},
          else: state

      true ->
        owner = self()
        opts = state.codex.options

        Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
          send(owner, {:codex_connected, CodexBackend.connect(opts, owner)})
        end)

        codex = %{state.codex | status: :connecting}
        next = %{state | codex: codex, notice: "connecting to Codex App Server…"}
        if show_overlay?, do: %{next | overlay: codex_connecting_overlay()}, else: next
    end
  end

  defp refresh_codex(%{codex: %{client: client}} = state) when is_pid(client) do
    owner = self()

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      send(owner, {:codex_refreshed, CodexBackend.refresh(client)})
    end)

    put_in(state.codex.status, :refreshing)
  end

  defp refresh_codex(state), do: ensure_codex(state, true)

  defp reconnect_codex(state) do
    codex = %{
      state.codex
      | client: nil,
        status: :idle,
        account: nil,
        models: [],
        rate_limits: nil
    }

    ensure_codex(%{state | codex: codex}, true)
  end

  defp start_codex_login(%{codex: %{client: client}} = state) when is_pid(client) do
    owner = self()

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      send(owner, {:codex_login_started, CodexClient.login_chatgpt(client)})
    end)

    codex = %{state.codex | status: :authenticating, login: nil}
    %{state | codex: codex, overlay: codex_connecting_overlay("starting ChatGPT sign-in…")}
  end

  defp start_codex_login(state), do: ensure_codex(state, true)

  defp logout_codex(%{codex: %{client: client}} = state) when is_pid(client) do
    owner = self()

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      send(owner, {:codex_logout_finished, CodexClient.logout(client)})
    end)

    %{
      state
      | overlay: codex_connecting_overlay("signing out…"),
        notice: "signing out of ChatGPT…"
    }
  end

  defp logout_codex(state), do: state

  defp cancel_codex_login(%{codex: %{client: client}} = state, login_id) when is_pid(client) do
    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      CodexClient.request(client, "account/login/cancel", %{"loginId" => login_id})
    end)

    codex = %{state.codex | status: :ready, login: nil}
    codex_account_overlay(%{state | codex: codex, notice: "ChatGPT sign-in cancelled"})
  end

  defp cancel_codex_login(state, _login_id), do: state

  defp open_codex_url(state, url) do
    owner = self()
    opts = state.codex.options

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      send(owner, {:codex_browser_opened, CodexBackend.open_url(url, opts)})
    end)

    %{state | notice: "opened ChatGPT sign-in in your browser"}
  end

  defp codex_connecting_overlay(message \\ "connecting to Codex App Server…") do
    list_overlay(:codex_connecting, "Codex · ChatGPT subscription", message, [
      %{label: "Please wait…", value: nil}
    ])
  end

  defp codex_account_overlay(state) do
    account = state.codex.account

    {message, items} =
      cond do
        CodexBackend.chatgpt_account?(account) ->
          {
            CodexBackend.account_label(account) <>
              "\nOAuth credentials and refresh remain owned by Codex App Server and are shared with local Codex clients.",
            [
              %{label: "Refresh models and quota", value: :codex_refresh},
              %{label: "Sign out of ChatGPT (also signs out Codex CLI)", value: :codex_logout}
            ]
          }

        get_in(account || %{}, ["account", "type"]) == "apiKey" ->
          {
            "Codex is using an API key, not ChatGPT subscription access.",
            [
              %{label: "Sign in with ChatGPT subscription…", value: :codex_login},
              %{label: "Use Alto native backend", value: :alto}
            ]
          }

        true ->
          {
            "Sign in through the official managed ChatGPT OAuth flow. Alto never receives the token.",
            [
              %{label: "Sign in with ChatGPT subscription…", value: :codex_login},
              %{label: "Use Alto native backend", value: :alto}
            ]
          }
      end

    %{state | overlay: list_overlay(:codex_account, "Codex account", message, items)}
  end

  defp codex_login_overlay(%{"authUrl" => url, "loginId" => login_id}) do
    message =
      "Finish signing in with ChatGPT in your browser. This window stays open until App Server confirms login.\n\n" <>
        url

    list_overlay(:codex_account, "ChatGPT sign-in", message, [
      %{label: "Open sign-in page again", value: {:codex_open_url, url}},
      %{label: "Cancel sign-in", value: {:codex_cancel_login, login_id}}
    ])
  end

  defp codex_error_overlay(state, reason) do
    message = reason |> short_inspect() |> redact_secrets() |> String.slice(0, 500)

    items = [
      %{label: "Retry Codex connection", value: :codex_reconnect},
      %{label: "Use Alto native backend", value: :alto}
    ]

    codex = %{state.codex | status: {:error, reason}}

    %{
      state
      | codex: codex,
        overlay: list_overlay(:codex_error, "Codex unavailable", message, items),
        notice: "Codex needs attention"
    }
  end

  defp list_overlay(kind, title, message, items) do
    %{
      kind: kind,
      title: title,
      message: message,
      index: 0,
      filter: "",
      all_items: items,
      items: items
    }
  end

  defp ingest_codex_notification(state, "account/login/completed", %{"success" => true}) do
    reconnect_codex_account(state)
  end

  defp ingest_codex_notification(state, "account/login/completed", params) do
    reason = Map.get(params, "error") || "ChatGPT sign-in failed"
    codex_error_overlay(state, reason)
  end

  defp ingest_codex_notification(state, "account/updated", _params),
    do: reconnect_codex_account(state)

  defp ingest_codex_notification(state, "account/rateLimits/updated", params),
    do: put_in(state.codex.rate_limits, params)

  defp ingest_codex_notification(state, method, params) do
    case find_codex_run(state, params) do
      nil -> maybe_buffer_codex_event(state, method, params)
      {_local_id, run} -> apply_codex_run_event(state, run, method, params)
    end
  end

  defp reconnect_codex_account(%{codex: %{client: client}} = state) when is_pid(client) do
    owner = self()

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      result =
        with {:ok, account} <- CodexClient.account(client) do
          {:ok, %{client: client, account: account}}
        end

      send(owner, {:codex_connected, result})
    end)

    put_in(state.codex.status, :refreshing)
  end

  defp reconnect_codex_account(state), do: state

  defp find_codex_run(state, params) do
    thread_id = Map.get(params, "threadId") || Map.get(params, "conversationId")
    turn_id = Map.get(params, "turnId") || get_in(params, ["turn", "id"])

    Enum.find(state.runs, fn {_id, run} ->
      run.kind == :codex and run.thread_id == thread_id and
        (is_nil(turn_id) or is_nil(run.turn_id) or run.turn_id == turn_id)
    end)
  end

  defp maybe_buffer_codex_event(state, method, params) do
    if Enum.any?(state.runs, fn {_id, run} -> run.kind == :codex and run.status == :starting end) do
      pending = (state.codex.pending_events ++ [{method, params}]) |> Enum.take(-100)
      put_in(state.codex.pending_events, pending)
    else
      state
    end
  end

  defp replay_codex_events(state, run) do
    {matching, rest} =
      Enum.split_with(state.codex.pending_events, fn {_method, params} ->
        params["threadId"] == run.thread_id and
          (is_nil(params["turnId"]) or params["turnId"] == run.turn_id)
      end)

    state = put_in(state.codex.pending_events, rest)

    Enum.reduce(matching, state, fn {method, params}, acc ->
      apply_codex_run_event(acc, run, method, params)
    end)
  end

  defp replay_codex_requests(state, run) do
    {matching, rest} =
      Enum.split_with(state.codex.pending_requests, fn {_id, _method, params} ->
        (params["threadId"] || params["conversationId"]) == run.thread_id and
          (is_nil(params["turnId"]) or params["turnId"] == run.turn_id)
      end)

    state = put_in(state.codex.pending_requests, rest)

    Enum.reduce(matching, state, fn {id, method, params}, acc ->
      handle_codex_request(acc, id, method, params)
    end)
  end

  defp apply_codex_run_event(state, run, "item/agentMessage/delta", %{"delta" => delta}),
    do: State.append_assistant_delta(state, run.task_id, delta, :codex_assistant)

  defp apply_codex_run_event(state, run, "thread/tokenUsage/updated", %{"tokenUsage" => usage}) do
    state
    |> State.put_usage(run.task_id, Alto.Usage.from_codex(usage))
    |> put_in([Access.key!(:codex), Access.key!(:context_window)], usage["modelContextWindow"])
  end

  defp apply_codex_run_event(state, run, "item/started", %{"item" => item}) do
    case codex_item_summary(item) do
      nil -> state
      text -> State.append_entry(state, run.task_id, %{kind: :tool, text: text <> " …"})
    end
  end

  defp apply_codex_run_event(state, run, "item/completed", %{"item" => item}) do
    case codex_item_summary(item) do
      nil ->
        state

      text ->
        State.append_entry(state, run.task_id, %{
          kind: :tool,
          text: text <> " ✓",
          detail: short_inspect(item)
        })
    end
  end

  defp apply_codex_run_event(state, run, "turn/diff/updated", %{"diff" => diff}) do
    State.upsert_entry(state, run.task_id, {:codex_diff, run.turn_id}, %{
      kind: :system,
      text: "Codex updated the working diff",
      detail: diff
    })
  end

  defp apply_codex_run_event(state, run, "turn/completed", %{"turn" => turn}) do
    status = Map.get(turn, "status")
    error = get_in(turn, ["error", "message"])
    finish_codex_run(state, run, status, error)
  end

  defp apply_codex_run_event(state, run, "error", params) do
    text = Map.get(params, "message") || short_inspect(params)
    State.append_entry(state, run.task_id, %{kind: :error, text: text})
  end

  defp apply_codex_run_event(state, _run, _method, _params), do: state

  defp codex_item_summary(%{"type" => "commandExecution", "command" => command}),
    do: "command · " <> short_inspect(command)

  defp codex_item_summary(%{"type" => "fileChange"}), do: "file changes"
  defp codex_item_summary(%{"type" => "mcpToolCall", "tool" => tool}), do: "MCP · #{tool}"
  defp codex_item_summary(%{"type" => "dynamicToolCall", "tool" => tool}), do: "tool · #{tool}"
  defp codex_item_summary(_item), do: nil

  defp finish_codex_run(state, run, status, error) do
    completed? = status == "completed"
    catalog_status = if completed?, do: "completed", else: "failed"

    local_id =
      Enum.find_value(state.runs, fn {id, candidate} -> if candidate == run, do: id end)

    state =
      case Catalog.update_task(run.task_id, %{"status" => catalog_status}, state.catalog_opts) do
        {:ok, task} -> State.update_task_record(state, task)
        {:error, _reason} -> state
      end

    state =
      if completed? do
        state
      else
        State.append_entry(state, run.task_id, %{
          kind: :error,
          text: error || "Codex turn #{status || "failed"}"
        })
      end

    state
    |> drop_run(local_id)
    |> Map.put(:notice, if(completed?, do: "Codex run completed", else: "Codex run failed"))
    |> refresh_limits_after_turn()
  end

  defp refresh_limits_after_turn(%{codex: %{client: client}} = state) when is_pid(client) do
    owner = self()

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      send(owner, {:codex_limits_refreshed, CodexClient.rate_limits(client)})
    end)

    state
  end

  defp refresh_limits_after_turn(state), do: state

  defp fail_codex_start(state, local_id, run, reason) do
    state =
      case Catalog.update_task(run.task_id, %{"status" => "failed"}, state.catalog_opts) do
        {:ok, task} -> State.update_task_record(state, task)
        {:error, _reason} -> state
      end

    state
    |> State.append_entry(run.task_id, %{
      kind: :error,
      text: "Codex could not start: #{short_inspect(reason)}"
    })
    |> drop_run(local_id)
    |> Map.put(:notice, "Codex run failed to start")
  end

  defp handle_codex_request(state, id, method, params)
       when method in [
              "item/commandExecution/requestApproval",
              "item/fileChange/requestApproval",
              "item/permissions/requestApproval",
              "execCommandApproval",
              "applyPatchApproval"
            ] do
    case find_codex_run(state, params) do
      nil ->
        if Enum.any?(state.runs, fn {_run_id, run} ->
             run.kind == :codex and run.status == :starting
           end) do
          pending =
            (state.codex.pending_requests ++ [{id, method, params}])
            |> Enum.take(-20)

          put_in(state.codex.pending_requests, pending)
        else
          CodexClient.reject(state.codex.client, id, -32001, "no matching Alto task")
          state
        end

      {local_id, run} ->
        case run.approval_level do
          :ask ->
            request = %{
              id: "codex-#{id}",
              tool: codex_approval_tool(method),
              arguments: codex_approval_arguments(params),
              details: params
            }

            pending = %{
              backend: :codex,
              local_id: local_id,
              client: state.codex.client,
              request_id: id,
              method: method,
              params: params,
              request: request
            }

            show_pending_approval(
              state,
              pending,
              "Codex approval required · F8 approve / F9 deny"
            )

          :read_only ->
            CodexClient.respond(
              state.codex.client,
              id,
              codex_approval_response(method, {:deny, :read_only}, params)
            )

            state

          :full_access ->
            CodexClient.respond(
              state.codex.client,
              id,
              codex_approval_response(method, :approve, params)
            )

            state
        end
    end
  end

  defp handle_codex_request(state, id, _method, _params) do
    CodexClient.reject(state.codex.client, id)
    state
  end

  defp codex_approval_decision(method, :approve)
       when method in ["execCommandApproval", "applyPatchApproval"],
       do: "approved"

  defp codex_approval_decision(method, {:deny, _reason})
       when method in ["execCommandApproval", "applyPatchApproval"],
       do: "abort"

  defp codex_approval_decision(_method, :approve), do: "accept"
  defp codex_approval_decision(_method, {:deny, _reason}), do: "decline"

  defp codex_approval_response("item/permissions/requestApproval", :approve, params),
    do: %{"permissions" => Map.get(params, "permissions", %{}), "scope" => "turn"}

  defp codex_approval_response("item/permissions/requestApproval", {:deny, _reason}, _params),
    do: %{"permissions" => %{}, "scope" => "turn"}

  defp codex_approval_response(method, decision, _params),
    do: %{"decision" => codex_approval_decision(method, decision)}

  defp codex_approval_tool(method)
       when method in ["item/fileChange/requestApproval", "applyPatchApproval"],
       do: "Codex file changes"

  defp codex_approval_tool("item/permissions/requestApproval"), do: "Codex permissions"

  defp codex_approval_tool(_method), do: "Codex command"

  defp codex_approval_arguments(params),
    do:
      Map.take(params, [
        "command",
        "cwd",
        "reason",
        "fileChanges",
        "grantRoot",
        "permissions"
      ])

  defp credentials_opts(state), do: [credentials_path: state.credentials_path]

  defp merge_saved_profile(nil, saved), do: saved

  defp merge_saved_profile(prior, saved) do
    %{
      prior
      | label: saved.label,
        default_model: saved.default_model,
        options: Keyword.put(prior.options, :base_url, Keyword.fetch!(saved.options, :base_url))
    }
  end

  defp human_provider_error(:provider_id_must_be_lowercase_slug),
    do: "ID must use lowercase letters, numbers, dots, dashes, or underscores"

  defp human_provider_error(:provider_name_required), do: "provider name is required"
  defp human_provider_error(:provider_base_url_required), do: "base URL is required"

  defp human_provider_error(:provider_base_url_must_be_http),
    do: "use an http:// or https:// URL"

  defp human_provider_error(reason), do: "could not save provider: #{short_inspect(reason)}"

  defp redact_secrets(text) do
    text
    |> String.replace(~r/(?i)(bearer\s+)[^\s\"',}\]]+/, "\\1[REDACTED]")
    |> String.replace(
      ~r/(?i)((?:api[_-]?key|token|secret)[^:]{0,8}:\s*)\"[^\"]*\"/,
      "\\1\"[REDACTED]\""
    )
  end

  defp model_id(%{id: id}), do: id
  defp model_id(%{"id" => id}), do: id

  defp model_label(model) do
    id = model_id(model)
    name = Map.get(model, :name) || Map.get(model, "name") || id
    context = Map.get(model, :context_length) || Map.get(model, "context_length")
    if context, do: "#{name} · #{id} · #{context} ctx", else: "#{name} · #{id}"
  end

  defp terminal_size do
    case ExRatatui.terminal_size() do
      {width, height} -> {width, height}
      _error -> {120, 36}
    end
  end

  defp short_inspect(term), do: inspect(term, limit: 8, printable_limit: 240)
end
