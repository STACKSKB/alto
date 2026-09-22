defmodule Alto.TUI.App do
  @moduledoc "Mouse-aware, multi-project terminal front end for the Alto coding harness."

  use ExRatatui.App

  alias Alto.Approvals.{AllowAll, Delegated, DenyAll}
  alias Alto.Event
  alias Alto.Harness.{Catalog, ProviderProfile, ProviderStore}
  alias Alto.TUI.{Menu, Backend, Selection, State, TextForm, View, WorkspaceForm}
  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}

  @submission_selection [
    :selected_task_id,
    :selected_project_id,
    :selected_backend,
    :selected_provider_id,
    :selected_model,
    :approval_level
  ]

  @approval_items [
    %{label: "ASK · prompt for each prepared mutation", value: :ask},
    %{label: "READ · deny prepared mutations", value: :read_only},
    %{label: "AUTO · approve prepared mutations", value: :full_access}
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

      state =
        state
        |> Map.put(:dimensions, dimensions)
        |> Map.put(:drag_poll, Alto.TUI.DragInput.poller(opts))
        |> State.ensure_visible_focus()

      send(self(), :prepare_backend)
      Process.send_after(self(), :tui_activity_tick, 250)
      {:ok, state}
    else
      nil -> {:error, :tui_config_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def render(state, frame) do
    Selection.widgets(state.selection, fn ->
      View.widgets(state, frame) |> Alto.TUI.Viewport.widgets()
    end) ++
      View.activity_widgets(state, frame)
  end

  @impl true
  def handle_event(event, state) do
    event = Alto.TUI.DragInput.latest(event, state.drag_poll)
    {width, height} = state.dimensions
    widgets = fn -> View.widgets(state, %{width: width, height: height}) end

    # Pane seams retain their resize gesture; Alt+drag can select their text too.
    seam? =
      not state.selection.active? and
        match?(%Mouse{kind: "down", button: "left", modifiers: []}, event) and
        View.hit_target(state, width, height, event.x, event.y) in [:left_seam, :right_seam]

    if seam? or state.dragging in [:left_seam, :right_seam] do
      route_event(event, %{state | selection: Selection.new()})
    else
      case Selection.event(state.selection, event, state.dimensions, widgets,
             content: fn -> View.selection_content(state, width, height) end,
             scroll_limit: fn {x, y} ->
               case View.hit_target(state, width, height, x, y) do
                 :transcript -> View.transcript_bottom_scroll(state)
                 :details -> View.details_bottom_scroll(state)
                 _ -> nil
               end
             end
           ) do
        {:pass, selection} ->
          route_event(event, %{state | selection: selection})

        {:handled, selection} ->
          {:noreply, apply_selection_scroll(state, selection)}

        {:click, mouse, selection} ->
          state = %{state | selection: selection}

          if View.hit_target(state, width, height, mouse.x, mouse.y) in [:left_seam, :right_seam],
            do: {:noreply, state},
            else: route_event(mouse, state)

        {:copy, text, selection} ->
          result = state.clipboard_write.(text)

          notice = Alto.TUI.Clipboard.notice(result)

          {:noreply, %{state | selection: selection, clipboard_text: text, notice: notice}}
      end
    end
  end

  defp apply_selection_scroll(state, selection) do
    state = %{state | selection: selection}
    {width, height} = state.dimensions

    case Selection.scroll_position(selection) do
      {{x, y}, offset} ->
        case View.hit_target(state, width, height, x, y) do
          :transcript -> %{state | transcript_scroll: offset, transcript_follow?: false}
          :details -> %{state | details_scroll: offset}
          _ -> state
        end

      nil ->
        state
    end
  end

  defp route_event(%Key{kind: kind, code: "v", modifiers: ["ctrl"]}, state)
       when kind != "release" do
    content =
      case state.clipboard_read.() do
        {:ok, text} -> text
        _ -> state.clipboard_text
      end

    if content == nil,
      do: {:noreply, %{state | notice: "Paste with your terminal's paste shortcut"}},
      else: route_event(%Paste{content: content}, state)
  end

  defp route_event(%Resize{width: width, height: height}, state),
    do:
      {:noreply,
       state
       |> Map.put(:dimensions, {width, height})
       |> State.reconcile_responsive_focus()}

  defp route_event(%Paste{content: content}, %{overlay: nil, focus: :composer} = state) do
    ExRatatui.textarea_insert_str(state.textarea, content)
    {:noreply, state}
  end

  defp route_event(%Paste{content: content}, %{overlay: %{kind: :workspace_form} = form} = state),
    do: {:noreply, %{state | overlay: WorkspaceForm.paste(form, content)}}

  defp route_event(%Paste{content: content}, %{overlay: overlay} = state)
       when not is_nil(overlay) do
    if overlay.kind in [:provider_form, :model_form] do
      {:noreply, text_form_result(state, TextForm.paste(overlay, content))}
    else
      {:noreply, filter_overlay(state, overlay.filter <> content)}
    end
  end

  defp route_event(%Paste{}, %{details_drawer_open?: true} = state),
    do: {:noreply, state, render?: false}

  defp route_event(%Paste{content: content}, %{type_to_compose?: true} = state) do
    ExRatatui.textarea_insert_str(state.textarea, content)
    {:noreply, %{state | focus: :composer}}
  end

  defp route_event(%Paste{}, state), do: {:noreply, state, render?: false}

  defp route_event(%Mouse{} = mouse, state), do: {:noreply, handle_mouse(state, mouse)}

  defp route_event(%Key{kind: "release"}, state), do: {:noreply, state, render?: false}

  defp route_event(%Key{} = key, %{overlay: overlay} = state) when not is_nil(overlay),
    do: {:noreply, overlay_key(state, key)}

  defp route_event(%Key{code: "esc"}, %{details_drawer_open?: true} = state),
    do: {:noreply, State.close_details_drawer(state)}

  defp route_event(%Key{code: "g", modifiers: ["ctrl"]}, state) do
    {:noreply, %{state | leader?: not state.leader?, notice: nil}}
  end

  defp route_event(%Key{} = key, %{leader?: true} = state) do
    case String.downcase(key.code || "") do
      "a" -> {:noreply, open_overlay(state, :approval)}
      "b" -> {:noreply, open_overlay(state, :backend)}
      "p" -> {:noreply, open_overlay(state, :provider)}
      "m" -> {:noreply, open_overlay(state, :model)}
      "r" -> {:noreply, open_overlay(state, :effort)}
      "e" -> {:noreply, toggle_composer_mode(state)}
      "w" -> {:noreply, open_overlay(state, :project)}
      "x" -> {:noreply, State.close_workspace(state, state.selected_project_id)}
      "t" -> {:noreply, open_overlay(state, :task)}
      "n" -> {:noreply, state |> State.new_task() |> Map.put(:leader?, false)}
      "d" -> {:noreply, toggle_details(state)}
      "esc" -> {:noreply, %{state | leader?: false, notice: nil}}
      "q" -> {:stop, state}
      _other -> {:noreply, %{state | leader?: false, notice: "unknown gear key"}}
    end
  end

  defp route_event(%Key{code: "f2"}, state), do: {:noreply, open_overlay(state, :approval)}
  defp route_event(%Key{code: "f3"}, state), do: {:noreply, open_overlay(state, :provider)}
  defp route_event(%Key{code: "f4"}, state), do: {:noreply, open_overlay(state, :model)}
  defp route_event(%Key{code: "f5"}, state), do: {:noreply, open_overlay(state, :backend)}
  defp route_event(%Key{code: "f6"}, state), do: {:noreply, toggle_composer_mode(state)}
  defp route_event(%Key{code: "f8"}, state), do: {:noreply, decide_approval(state, :approve)}

  defp route_event(%Key{code: "f9"}, state),
    do: {:noreply, decide_approval(state, {:deny, :user_denied})}

  defp route_event(%Key{code: "tab"}, state), do: {:noreply, State.focus_next(state)}

  defp route_event(%Key{code: "back_tab"}, state),
    do: {:noreply, State.focus_next(state, :previous)}

  defp route_event(%Key{code: "c", modifiers: ["ctrl"]}, state) do
    case active_run(state) do
      nil ->
        {:stop, state}

      {_id, run} ->
        {:noreply, stop_active_run(state, run)}
    end
  end

  defp route_event(%Key{code: "esc"}, state) do
    case active_run(state) do
      nil -> {:noreply, state}
      {_id, run} -> {:noreply, stop_active_run(state, run)}
    end
  end

  defp route_event(%Key{code: "enter", modifiers: modifiers} = key, %{focus: :composer} = state) do
    if "shift" in modifiers do
      forward_textarea(state, key)
    else
      if "ctrl" in modifiers do
        {:noreply, submit(state, :steer)}
      else
        {:noreply, submit(state)}
      end
    end
  end

  defp route_event(%Key{} = key, %{focus: :composer} = state), do: forward_textarea(state, key)

  defp route_event(
         %Key{} = key,
         %{type_to_compose?: true, details_drawer_open?: false} = state
       ) do
    if printable_key?(key) do
      forward_textarea(%{state | focus: :composer}, key)
    else
      {:noreply, navigate(state, key)}
    end
  end

  defp route_event(%Key{} = key, state), do: {:noreply, navigate(state, key)}

  @impl true
  def handle_info({:tui_deferred_input, event}, state), do: handle_event(event, state)

  def handle_info(:tui_activity_tick, state) do
    Process.send_after(self(), :tui_activity_tick, 250)
    active? = State.activity(state) != nil

    next = %{
      state
      | activity_tick: state.activity_tick + 1,
        activity_started_ms:
          if(active?,
            do: state.activity_started_ms || System.system_time(:millisecond),
            else: nil
          )
    }

    {:noreply, next, render?: active?}
  end

  def handle_info({:tui_selection_scroll, token}, state) do
    case Selection.autoscroll(state.selection, token) do
      {:scrolled, selection} -> {:noreply, apply_selection_scroll(state, selection)}
      {:idle, selection} -> {:noreply, %{state | selection: selection}, render?: false}
    end
  end

  def handle_info({:alto_tui_event, local_id, %Event{} = event, sender, ref}, state) do
    next = ingest_event(state, local_id, event)
    send(sender, {ref, :ok})
    {:noreply, next}
  end

  def handle_info({:alto_tui_event, local_id, %Event{} = event}, state) do
    {:noreply, ingest_event(state, local_id, event)}
  end

  def handle_info({:alto_approval_request, local_id, request, waiter}, state) do
    local_id =
      Enum.find_value(state.runs, local_id, fn {id, run} ->
        if MapSet.member?(Map.get(run, :approval_ids, MapSet.new()), request.id), do: id
      end)

    pending = %{
      local_id: local_id,
      request: request,
      respond: &send(waiter, {:alto_approval_decision, request.id, &1})
    }

    {:noreply, show_pending_approval(state, pending, "approval required · F8 approve / F9 deny")}
  end

  def handle_info({:alto_models_loaded, profile_id, result}, state) do
    state = %{state | model_loading: MapSet.delete(state.model_loading, profile_id)}

    case result do
      {:ok, models} ->
        state = %{state | models: Map.put(state.models, profile_id, models)}

        state =
          if (state.overlay && state.overlay.kind in [:model, :effort]) and
               state.selected_provider_id == profile_id do
            open_overlay(%{state | overlay: nil}, state.overlay.kind)
          else
            state
          end

        {:noreply, state}

      {:error, reason} ->
        {:noreply, model_error_overlay(state, profile_id, reason)}
    end
  end

  def handle_info({:alto_tui_send_input, task_id}, state) do
    {:noreply, send_input(state, task_id)}
  end

  # Completion is a runner notification, independent of its implementation.
  def handle_info({:alto_runner_result, ref, result}, state) when is_reference(ref) do
    case find_run(state, ref: ref) do
      nil -> {:noreply, state, render?: false}
      {local_id, run} -> {:noreply, finish_runner_result(state, local_id, run, result)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case find_run(state, monitor: monitor) do
      nil ->
        {:noreply, state, render?: false}

      {local_id, run} ->
        {:noreply, finish_runner_result(state, local_id, run, {:error, {:run_exited, reason}})}
    end
  end

  def handle_info(:prepare_backend, state), do: {:noreply, prepare_selected_backend(state)}

  def handle_info(message, state) do
    case Backend.message(state, message) do
      :pass -> {:noreply, state, render?: false}
      result -> result
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.runs, fn {_id, run} -> cancel_run(run) end)
    :ok
  end

  defp submit(state, mode \\ :follow_up) do
    prompt = state.textarea |> ExRatatui.textarea_get_value() |> String.trim()

    cond do
      state.selected_project_id == nil ->
        %{state | notice: "Open a workspace first · ^G W"}

      prompt == "" and not task_running?(state, state.selected_task_id) and
          State.input_pending?(state, state.selected_task_id) ->
        send_input(state, state.selected_task_id)

      prompt == "" ->
        %{state | notice: "write a message first"}

      task_running?(state, state.selected_task_id) ->
        queue_message(state, prompt, mode)

      map_size(state.runs) >= 32 ->
        %{state | notice: "too many active runs; finish or cancel one first"}

      true ->
        submit_backend(state, prompt)
    end
  end

  defp queue_message(state, prompt, mode) do
    if mode == :steer and Backend.ui(state, :steering?) != true,
      do: %{state | notice: "this backend cannot steer · press Enter to queue a follow-up"},
      else: queue_input(state, state.selected_task_id, prompt, mode)
  end

  defp queue_input(state, task_id, prompt, mode) do
    with :ok <- input_route_available(state, task_id),
         {:ok, state} <- ensure_input(state, task_id),
         input <- Map.fetch!(state.inputs, task_id),
         :ok <- one_follow_up_available(input, mode),
         {:ok, _input_id} <- Alto.Input.put(input, prompt, mode) do
      ExRatatui.textarea_set_value(state.textarea, "")

      state
      |> Map.update!(:input_routes, fn routes ->
        route =
          Map.get_lazy(routes, task_id, fn ->
            %{selection: Map.take(state, @submission_selection)}
          end)

        Map.put(routes, task_id, route)
      end)
      |> Map.put(:notice, input_notice(mode))
    else
      {:error, :follow_up_pending} ->
        %{state | notice: "one message already queued · draft kept · Esc stops current run"}

      {:error, :pending_task_capacity} ->
        %{state | notice: "queued message limit reached · draft kept"}

      {:error, reason} ->
        %{state | notice: "input not accepted: #{human_error(reason)} · draft kept"}
    end
  end

  defp one_follow_up_available(_input, :steer), do: :ok

  defp one_follow_up_available(input, :follow_up) do
    if Enum.any?(Alto.Input.list(input), &(&1.mode == :follow_up)),
      do: {:error, :follow_up_pending},
      else: :ok
  end

  defp input_notice(:steer), do: "steering message accepted · Enter queues a follow-up"
  defp input_notice(:follow_up), do: "message queued for the next turn · Esc stops current run"

  defp input_route_available(state, task_id) do
    if Map.has_key?(state.input_routes, task_id) or map_size(state.input_routes) < 32,
      do: :ok,
      else: {:error, :pending_task_capacity}
  end

  defp ensure_input(state, task_id) do
    case Map.get(state.inputs, task_id) do
      input when is_pid(input) ->
        {:ok, state}

      nil ->
        case Alto.Input.start_link() do
          {:ok, input} -> {:ok, put_in(state.inputs[task_id], input)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ensure_input_for_task(state, task), do: ensure_input(state, task["id"])

  defp send_input(state, task_id) do
    case {task_running?(state, task_id), Map.get(state.inputs, task_id)} do
      {false, input} when is_pid(input) and map_size(state.runs) < 32 ->
        case Alto.Input.take(input) do
          :empty ->
            state

          {:error, :input_in_use} ->
            # Completion is delivered before the supervised runner releases
            # the channel. Retry after that handoff so accepted input survives
            # the completion race instead of crashing or being dropped.
            retry_input(state, task_id)

          {:ok, entry} ->
            route = Map.get(state.input_routes, task_id, %{})

            foreground =
              Map.take(state, @submission_selection ++ [:transcript_scroll, :transcript_follow?])

            draft = ExRatatui.textarea_get_value(state.textarea)

            next =
              state |> Map.merge(Map.get(route, :selection, %{})) |> submit_backend(entry.text)

            ExRatatui.textarea_set_value(state.textarea, draft)
            next = Map.merge(next, foreground)

            if task_running?(next, task_id) do
              clear_input_route(next, task_id)
            else
              case Alto.Input.put(input, entry.text, entry.mode) do
                {:ok, _id} ->
                  %{
                    next
                    | input_routes: Map.put(next.input_routes, task_id, route),
                      notice: "input retained · Enter sends"
                  }

                {:error, reason} ->
                  %{next | notice: "input unavailable: #{human_error(reason)} · draft kept"}
              end
            end

          {:error, reason} ->
            %{state | notice: "input unavailable: #{human_error(reason)} · draft kept"}
        end

      {false, _input} ->
        %{state | notice: "no input is available for this task"}

      _ ->
        state
    end
  end

  defp retry_input(state, task_id) do
    Process.send_after(self(), {:alto_tui_send_input, task_id}, 10)
    %{state | notice: "input pending · Enter sends"}
  end

  def finish_queued(state, task_id, true) do
    if State.input_pending?(state, task_id) do
      send(self(), {:alto_tui_send_input, task_id})
      %{state | notice: state.notice <> " · input retained (Enter sends)"}
    else
      state
    end
  end

  def finish_queued(state, task_id, false) do
    if State.input_pending?(state, task_id),
      do: %{state | notice: state.notice <> " · queued message paused (Enter sends)"},
      else: state
  end

  defp clear_input_route(state, task_id) do
    if State.input_pending?(state, task_id),
      do: state,
      else: %{state | input_routes: Map.delete(state.input_routes, task_id)}
  end

  defp stop_active_run(state, run) do
    cancel_run(run)

    runs =
      Map.new(state.runs, fn {id, candidate} ->
        {id, if(candidate == run, do: Map.put(candidate, :phase, "cancelling"), else: candidate)}
      end)

    %{state | runs: runs, notice: "cancelling run · draft and queued message kept"}
  end

  defp submit_backend(state, prompt) do
    case Backend.ui(state, {:submit, prompt}) do
      :pass -> submit_runner(state, prompt)
      next -> next
    end
  end

  defp submit_runner(state, prompt) do
    profile = State.selected_profile(state)

    cond do
      is_nil(profile) and Keyword.fetch(state.run_options, :provider) != {:ok, nil} ->
        %{state | notice: "choose a provider before sending"}

      not is_nil(profile) and (is_nil(state.selected_model) or state.selected_model == "") ->
        open_overlay(%{state | notice: "choose a model before sending"}, :model)

      true ->
        with {:ok, state, task} <- ensure_task(state, prompt),
             {:ok, state} <- ensure_input_for_task(state, task),
             {:ok, run_options} <- run_options(state, profile),
             {:ok, handle, completion_ref, local_id} <- start_task(task, prompt, run_options) do
          attach_run(
            state,
            local_id,
            %{
              kind: :alto,
              adapter: Backend.lookup(state.run_options, state.selected_backend),
              handle: handle,
              task_id: task["id"],
              ref: completion_ref,
              phase: "starting",
              approval_ids: MapSet.new(),
              started_at_ms: System.system_time(:millisecond)
            },
            prompt,
            "run started"
          )
        else
          {:error, reason} -> %{state | notice: "cannot start: #{human_error(reason)}"}
        end
    end
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
      |> Alto.Events.attach(&deliver_event(owner, local_id, &1))
      |> Keyword.update(
        :tool_context_metadata,
        %{approval_sink: owner},
        &Map.put(&1, :approval_sink, owner)
      )

    with {:ok, handle} <- do_start_task(task, prompt, run_options) do
      case Alto.subscribe(handle) do
        {:ok, ref} ->
          {:ok, handle, ref, local_id}

        {:error, reason} ->
          Alto.terminate(handle, :subscription_failed)
          {:error, reason}
      end
    end
  end

  def attach_run(state, local_id, run, prompt, notice) do
    ExRatatui.textarea_set_value(state.textarea, "")

    state = sync_run_task(state, run)

    state
    |> State.append_entry(run.task_id, %{kind: :user, text: prompt})
    |> Map.update!(:runs, &Map.put(&1, local_id, run))
    |> Map.put(:notice, notice)
    |> Map.put(:transcript_scroll, 0)
    |> Map.put(:transcript_follow?, true)
  end

  defp do_start_task(task, prompt, run_options) do
    backend = State.task_backend(task)

    with {:ok, module, options} <- Backend.lookup(run_options, backend),
         true <- function_exported?(module, :start, 4),
         {:ok, %Alto.Runner.Handle{} = handle} <- module.start(task, prompt, run_options, options) do
      {:ok, handle}
    else
      false -> {:error, :backend_requires_interactive_start}
      error -> error
    end
  end

  def ensure_task(%{selected_task_id: nil} = state, prompt) do
    title = prompt |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 96)

    opts = Keyword.put(state.catalog_opts, :backend, Atom.to_string(state.selected_backend))

    case Catalog.create_task(state.selected_project_id, title, opts) do
      {:ok, task} -> {:ok, State.put_task(state, task), task}
      {:error, reason} -> {:error, reason}
    end
  end

  def ensure_task(state, _prompt), do: {:ok, state, State.selected_task(state)}

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

      opts =
        Keyword.put(opts, :input, Map.get(state.inputs, state.selected_task_id))

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

    options = maybe_context_window(options, selected_model_metadata(state, profile))

    options =
      if effort = State.selected_effort(state),
        do: Keyword.put(options, :reasoning_effort, effort),
        else: options

    {module, options}
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

  defp finish_runner_result(state, local_id, _run, result) do
    {status, session_id, entry, notice, persistence} =
      case result do
        {:ok, completed} ->
          {"completed", completed.session_id, nil, "run completed", completed.persistence}

        {:error, reason, completed} ->
          {"failed", completed.session_id, %{kind: :error, text: human_error(reason)},
           "run failed", completed.persistence}

        other ->
          {"failed", nil, %{kind: :error, text: human_error(other)}, "run failed", nil}
      end

    {entry, notice} = persistence_feedback(entry, notice, persistence)

    finish_run(state, local_id, status,
      session_id: session_id,
      entry: entry,
      notice: notice,
      continue?: status == "completed" and not match?({:degraded, _}, persistence)
    )
  end

  def finish_run(state, local_id, status, opts \\ []) do
    run = Map.fetch!(state.runs, local_id)
    changes = %{"status" => status} |> maybe_change("conversation_id", opts[:session_id])

    state =
      case Catalog.update_task(run.task_id, changes, state.catalog_opts) do
        {:ok, task} -> State.update_task_record(state, task)
        {:error, _reason} -> state
      end

    state = if opts[:entry], do: State.append_entry(state, run.task_id, opts[:entry]), else: state

    state
    |> drop_run(local_id)
    |> Map.put(:notice, opts[:notice])
    |> finish_queued(run.task_id, Keyword.get(opts, :continue?, status == "completed"))
  end

  def update_run(state, local_id, changes) when is_binary(local_id) do
    update_in(state.runs[local_id], &Map.merge(&1, Map.new(changes)))
  end

  def update_run(state, run, changes) do
    case Enum.find(state.runs, fn {_id, candidate} -> candidate == run end) do
      {local_id, _run} -> update_run(state, local_id, changes)
      nil -> state
    end
  end

  def sync_run_task(state, run) do
    changes =
      %{"status" => "active"}
      |> maybe_change("backend", run[:backend_id] && Atom.to_string(run.backend_id))
      |> maybe_change("conversation_id", run[:thread_id])

    case Catalog.update_task(run.task_id, changes, state.catalog_opts) do
      {:ok, task} -> State.update_task_record(state, task)
      {:error, _reason} -> state
    end
  end

  defp maybe_change(map, _key, nil), do: map
  defp maybe_change(map, key, value), do: Map.put(map, key, value)

  defp persistence_feedback(entry, notice, {:degraded, errors}) do
    warning = %{kind: :error, text: "persistence degraded", detail: human_error(errors)}
    {entry || warning, notice <> " · persistence degraded"}
  end

  defp persistence_feedback(entry, notice, _status), do: {entry, notice}

  defp ingest_event(state, local_id, %Event{} = event) do
    case Map.get(state.runs, local_id) do
      nil ->
        state

      run ->
        state = update_run_phase(state, local_id, event)
        do_ingest_event(state, run.task_id, event)
    end
  end

  defp update_run_phase(state, local_id, %Event{} = event) do
    run = Map.fetch!(state.runs, local_id)

    phase = Alto.TUI.Activity.phase(event.type, Map.get(run, :phase, "working"))

    run = if Map.get(run, :phase) == "cancelling", do: run, else: Map.put(run, :phase, phase)

    run =
      case event do
        %Event{type: :approval_requested, data: %{request: request}} ->
          Map.update(run, :approval_ids, MapSet.new([request.id]), &MapSet.put(&1, request.id))

        _ ->
          run
      end

    state = put_in(state.runs[local_id], run)

    case event do
      %Event{type: :approval_resolved, data: %{request: request}} ->
        clear_approvals(state, &(&1.request.id == request.id))

      _ ->
        state
    end
  end

  defp clear_approvals(state, predicate) do
    pending = Enum.reject(state.pending_approvals, predicate)
    state = reset_approval_view(state, pending)

    if pending == [] and state.details_drawer_auto_opened?,
      do: State.close_details_drawer(state),
      else: state
  end

  defp do_ingest_event(state, task_id, %Event{type: :model_reasoning_delta, data: %{text: text}}),
    do: State.append_assistant_delta(state, task_id, text, :reasoning)

  defp do_ingest_event(state, task_id, %Event{type: :model_delta, data: %{text: text}}),
    do: State.append_assistant_delta(state, task_id, text)

  defp do_ingest_event(state, task_id, %Event{type: :input_received, data: %{text: text}}) do
    state = clear_input_route(state, task_id)

    # Native input continues within the same run, bypassing attach_started_run.
    # Insert its user turn before any response deltas can extend the previous one.
    state = State.append_entry(state, task_id, %{kind: :user, text: text})

    if state.selected_task_id == task_id,
      do: %{state | notice: "message started"},
      else: state
  end

  defp do_ingest_event(state, task_id, %Event{type: :model_completed, data: data}) do
    State.update_usage(state, task_id, Map.get(data, :usage, %{}))
  end

  defp do_ingest_event(state, task_id, %Event{type: type, data: data})
       when type in [:tool_started, :tool_completed, :tool_failed] do
    entry = Alto.ToolDisplay.entry(type, data)
    key = {:tool, data[:operation_id] || data[:call_id]}
    State.upsert_entry(state, task_id, key, entry)
  end

  defp do_ingest_event(state, task_id, %Event{
         type: :context_compacted,
         data: %{strategy: :handoff} = data
       }) do
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

  def open_overlay(state, kind) do
    state = %{state | leader?: false, notice: nil}

    contribution = Backend.ui(state, {:overlay, kind})
    result = if contribution == :pass, do: overlay_items(state, kind), else: contribution

    case result do
      {:state, next} ->
        next

      {:load, profile} ->
        owner = self()

        Task.start(fn ->
          send(
            owner,
            {:alto_models_loaded, profile.id,
             ProviderProfile.models(profile, credentials_path: state.credentials_path)}
          )
        end)

        overlay =
          Menu.new(kind, "models · loading #{profile.label}…", [
            %{label: "Loading model catalog…", value: nil}
          ])

        %{state | overlay: overlay, model_loading: MapSet.put(state.model_loading, profile.id)}

      {:ok, title, items, selected} ->
        %{state | overlay: Menu.new(kind, title, items, selected)}

      {:error, reason} ->
        %{state | notice: reason}
    end
  end

  defp overlay_items(state, :effort) do
    case State.effort_choices(state) do
      [] ->
        profile = State.selected_profile(state)

        cond do
          profile &&
            not Map.has_key?(state.models, profile.id) &&
              not MapSet.member?(state.model_loading, profile.id) ->
            {:load, profile}

          true ->
            {:error, "This model does not advertise effort selection"}
        end

      choices ->
        {:ok, "reasoning effort · next turn",
         [
           %{label: "Provider default", value: :default}
           | Enum.map(choices, &%{label: &1, value: &1})
         ], State.selected_effort(state) || :default}
    end
  end

  defp overlay_items(state, :approval),
    do: {:ok, "approval level", @approval_items, state.approval_level}

  defp overlay_items(state, :backend) do
    items = Backend.items(state.run_options)

    {:ok, "execution backend", items, state.selected_backend}
  end

  defp overlay_items(state, :provider) do
    setup = [
      %{label: "＋ Add OpenAI-compatible provider…", value: {:configure_provider, nil}}
    ]

    configure =
      case State.selected_profile(state) do
        %{provider: {Alto.Providers.OpenAICompatible, _}} = profile ->
          [%{label: "⚙ Configure #{profile.label}…", value: {:configure_provider, profile.id}}]

        _other ->
          []
      end

    profiles =
      Enum.map(state.profiles, &%{label: &1.label <> " · " <> &1.id, value: &1.id})

    {:ok, "providers · select or configure", setup ++ configure ++ profiles,
     state.selected_provider_id}
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
      [%{label: "Open another folder…", value: :new_workspace}] ++
        if(state.selected_project_id,
          do: [%{label: "Close workspace · ^G X", value: :close_workspace}],
          else: []
        ) ++
        Enum.map(
          State.open_projects(state),
          &%{label: &1["name"] <> " · " <> &1["root"], value: &1["id"]}
        )

    {:ok, "workspaces · type to filter", items, state.selected_project_id}
  end

  defp overlay_items(state, :task) do
    items =
      state.tasks
      |> Map.get(state.selected_project_id, [])
      |> Enum.map(&%{label: &1["status"] <> " · " <> &1["title"], value: &1["id"]})

    {:ok, "tasks · type to filter", [%{label: "+ New task", value: :new_task} | items],
     state.selected_task_id}
  end

  defp overlay_key(%{overlay: %{kind: :workspace_form} = form} = state, key),
    do: workspace_form_result(state, WorkspaceForm.key(form, key))

  defp overlay_key(%{overlay: %{kind: kind} = form} = state, key)
       when kind in [:provider_form, :model_form],
       do: text_form_result(state, TextForm.key(form, key))

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

  defp filter_overlay(state, filter),
    do: %{state | overlay: Menu.filter(state.overlay, filter)}

  defp move_overlay(state, delta),
    do: %{state | overlay: Menu.move(state.overlay, delta)}

  defp select_overlay(%{overlay: overlay} = state) do
    items = Menu.items(overlay)
    index = overlay.index

    case Enum.at(items, index) do
      nil ->
        state

      %{value: nil} ->
        state

      %{value: {:select_backend, backend}} ->
        select_backend(state, backend)

      %{value: :new_workspace} ->
        open_workspace_form(state)

      %{value: :close_workspace} ->
        State.close_workspace(state, state.selected_project_id)

      %{value: :new_task} ->
        State.new_task(state)

      %{value: {:configure_provider, profile_id}} ->
        open_provider_form(state, profile_id)

      %{value: {:retry_models, profile_id}} ->
        retry_models(state, profile_id)

      %{value: {:enter_model, profile_id}} ->
        open_model_form(state, profile_id)

      %{value: value} ->
        case Backend.ui(state, {:select, value}) do
          :pass -> apply_selection(state, state.overlay.kind, value)
          next -> next
        end
    end
  end

  defp apply_selection(state, :effort, value) do
    if value == :default or value in State.effort_choices(state) do
      efforts =
        if value == :default,
          do: Map.delete(state.efforts, State.effort_key(state)),
          else: Map.put(state.efforts, State.effort_key(state), value)

      %{state | efforts: efforts, overlay: nil, notice: "effort: #{value} · applies next turn"}
    else
      %{state | overlay: nil, notice: "Effort is not supported by this model"}
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

    activate_target(state, View.hit_target(state, width, height, x, y), x)
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
      :details -> scroll_details(state, delta)
      _other -> state
    end
  end

  defp handle_mouse(state, _mouse), do: state

  defp activate_target(state, seam, _x) when seam in [:left_seam, :right_seam],
    do: %{state | dragging: seam}

  defp activate_target(state, :new_workspace, _x), do: open_workspace_form(state)
  defp activate_target(state, {:close_workspace, id}, _x), do: State.close_workspace(state, id)

  defp activate_target(state, {:rail_row, row}, _x) do
    selected = state |> State.select_rail_row(row) |> prepare_selected_backend()

    case Enum.at(State.rail_rows(state), row) do
      %{kind: :project} -> State.new_task(selected)
      _ -> %{selected | focus: :rail}
    end
  end

  defp activate_target(state, {:setting, :entry_mode}, _x), do: toggle_composer_mode(state)
  defp activate_target(state, {:setting, :details}, _x), do: toggle_details(state)
  defp activate_target(state, {:setting, kind}, _x), do: open_overlay(state, kind)

  defp activate_target(state, pane, _x) when pane in [:composer, :transcript, :details],
    do: %{state | focus: pane}

  defp activate_target(state, target, _x)
       when target in [:details_close, :details_drawer_outside],
       do: State.close_details_drawer(state)

  defp activate_target(state, {:approval, decision}, _x),
    do: decide_approval(state, approval_decision(decision))

  defp activate_target(%{overlay: %{kind: :workspace_form}} = state, {:overlay_row, row}, x) do
    {width, height} = state.dimensions
    rect = WorkspaceForm.rect(width, height)

    workspace_form_result(
      state,
      WorkspaceForm.click(state.overlay, row, x - rect.x - 1, rect.height)
    )
  end

  defp activate_target(state, {:overlay_row, row}, _x), do: handle_overlay_click(state, row)
  defp activate_target(state, :overlay_outside, _x), do: %{state | overlay: nil}
  defp activate_target(state, _target, _x), do: state

  defp scroll_details(state, delta),
    do: %{
      state
      | details_scroll:
          min(max(state.details_scroll + delta, 0), View.details_bottom_scroll(state))
    }

  defp navigate(state, %Key{code: code}) when code in ["down", "j", "up", "k"] do
    delta = if code in ["down", "j"], do: 1, else: -1

    case state.focus do
      :rail -> move_rail(state, delta)
      :transcript -> scroll_transcript(state, delta)
      :details -> scroll_details(state, delta)
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
    pending.respond.(decision)

    next = %{reset_approval_view(state, rest) | notice: approval_notice(decision)}

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

  def show_pending_approval(state, pending, notice) do
    next = %{
      reset_approval_view(state, state.pending_approvals ++ [pending])
      | details_visible?: true,
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

  defp reset_approval_view(state, pending) do
    changed? = List.first(state.pending_approvals) != List.first(pending)

    %{
      state
      | pending_approvals: pending,
        details_scroll: if(changed?, do: 0, else: state.details_scroll),
        selection: if(changed?, do: Selection.new(), else: state.selection)
    }
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

  defp cancel_run(%{adapter: {:ok, module, opts}} = run), do: module.cancel(run, :user, opts)

  defp cancel_run(_run), do: :ok

  def find_run(state, matcher) do
    Enum.find(state.runs, fn {_id, run} ->
      Enum.all?(matcher, fn {key, value} -> run[key] == value end)
    end)
  end

  def drop_run(state, local_id) do
    case Map.get(state.runs, local_id) do
      %{monitor: monitor} -> Process.demonitor(monitor, [:flush])
      _ -> :ok
    end

    state
    |> Map.update!(:runs, &Map.delete(&1, local_id))
    |> clear_approvals(&(Map.get(&1, :local_id) == local_id))
  end

  defp put_overlay_index(state, row) do
    index = row |> max(0) |> min(max(length(Menu.items(state.overlay)) - 1, 0))
    %{state | overlay: %{state.overlay | index: index}}
  end

  defp model_error_overlay(state, profile_id, reason) do
    profile = Enum.find(state.profiles, &(&1.id == profile_id))

    configure =
      if match?(%{provider: {Alto.Providers.OpenAICompatible, _}}, profile) do
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
      |> human_error()
      |> redact_secrets()
      |> String.slice(0, 1_000)

    %{
      state
      | overlay:
          Menu.new(:model_error, "model catalog unavailable", items) |> Map.put(:message, message),
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

    stored? = profile && ProviderStore.api_key_saved?(profile, credentials_opts(state))

    key_placeholder =
      if(stored? == true,
        do: "(saved — leave blank to keep)",
        else: "(optional for local providers)"
      )

    fields = [
      {:id, "ID", profile && profile.id, [locked?: not new?]},
      {:label, "Name", profile && profile.label, []},
      {:base_url, "Base URL", profile && Keyword.get(elem(profile.provider, 1), :base_url), []},
      {:api_key, "API key", "", [secret?: true, placeholder: key_placeholder]},
      {:model, "Default model", profile && profile.default_model, []}
    ]

    %{
      state
      | overlay:
          TextForm.new(
            :provider_form,
            if(new?, do: "add provider", else: "configure #{profile.label}"),
            fields,
            intro: "Credentials are saved privately outside the workspace.",
            hint: "Tab/↑↓ fields · Enter next/save · ^S save · Esc",
            buttons: ["[ Save provider ]", "[ Cancel ]"],
            prefix_width: 16,
            width_percent: 72,
            height_percent: 66,
            field_index: if(new?, do: 0, else: 3),
            after_save:
              if(state.overlay && state.overlay.kind == :model_error, do: :model, else: nil)
          ),
        notice: nil
    }
  end

  defp open_workspace_form(state) do
    project = State.selected_project(state)
    base = if project, do: project["root"], else: File.cwd!()

    %{
      state
      | overlay: WorkspaceForm.new(base, "this computer", Enum.map(state.projects, & &1["root"])),
        leader?: false
    }
  end

  defp workspace_form_result(state, :cancel), do: %{state | overlay: nil}
  defp workspace_form_result(state, {:edit, form}), do: %{state | overlay: form}

  defp workspace_form_result(state, {:create, path}) do
    case Alto.Harness.Folders.create(path, state.overlay.base) do
      {:ok, root} -> workspace_form_result(state, {:submit, root})
      {:error, reason} -> put_in(state.overlay.error, Alto.Display.error(reason))
    end
  end

  defp workspace_form_result(state, {:submit, path}) do
    case State.open_workspace(state, path) do
      {:ok, next} ->
        %{next | overlay: nil}

      {:error, {:project_not_directory, _}} ->
        put_in(state.overlay.error, "Folder does not exist. Ctrl+N creates it.")

      {:error, :invalid_workspace_path} ->
        put_in(state.overlay.error, "Enter a folder path on one line.")

      {:error, reason} ->
        put_in(state.overlay.error, "Could not open workspace: #{Alto.Display.error(reason)}")
    end
  end

  defp open_model_form(state, profile_id) do
    %{
      state
      | selected_provider_id: profile_id,
        overlay:
          TextForm.new(
            :model_form,
            "exact model ID",
            [{:model, "Model ID", "", []}],
            intro: "Use the provider's exact model identifier.",
            hint: "Enter use · Esc",
            buttons: ["[ Use model ]", "[ Cancel ]"],
            prefix_width: 12,
            width_percent: 62,
            height_percent: 42,
            button_gap: 1,
            profile_id: profile_id
          )
    }
  end

  defp text_form_result(state, :cancel), do: %{state | overlay: nil}
  defp text_form_result(state, {:edit, form}), do: %{state | overlay: form}

  defp text_form_result(%{overlay: %{kind: :provider_form}} = state, :submit),
    do: save_provider_form(state)

  defp text_form_result(%{overlay: %{kind: :model_form} = form} = state, :submit) do
    model = form |> TextForm.value() |> String.trim()

    if model == "",
      do: put_in(state.overlay.error, "model ID is required"),
      else: %{state | selected_model: model, overlay: nil, notice: "model: #{model}"}
  end

  defp save_provider_form(state) do
    attrs = TextForm.values(state.overlay)

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

  defp handle_overlay_click(%{overlay: %{kind: kind} = form} = state, row)
       when kind in [:provider_form, :model_form],
       do: text_form_result(state, TextForm.click(form, row))

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
        select_backend_ui(%{state | overlay: nil})

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

        select_backend_ui(%{next | notice: "backend: #{backend}"})
    end
  end

  defp task_backend_locked?(nil), do: false

  defp task_backend_locked?(task),
    do: is_binary(task["conversation_id"])

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

  defp select_backend_ui(state) do
    case Backend.ui(state, :selected) do
      :pass -> state
      next -> next
    end
  end

  defp backend_model(state, backend) do
    case Backend.ui(%{state | selected_backend: backend}, :model) do
      :pass ->
        profile = State.selected_profile(state)
        profile && profile.default_model

      model ->
        model
    end
  end

  defp prepare_selected_backend(state) do
    case Backend.ui(state, :prepare) do
      :pass -> state
      next -> next
    end
  end

  defp credentials_opts(state), do: [credentials_path: state.credentials_path]

  defp merge_saved_profile(nil, saved), do: saved

  defp merge_saved_profile(
         %{provider: {module, options}} = prior,
         %{provider: {_, saved_options}} = saved
       ) do
    %{
      prior
      | label: saved.label,
        default_model: saved.default_model,
        provider:
          {module, Keyword.put(options, :base_url, Keyword.fetch!(saved_options, :base_url))}
    }
  end

  defp human_provider_error(:provider_id_must_be_lowercase_slug),
    do: "ID must use lowercase letters, numbers, dots, dashes, or underscores"

  defp human_provider_error(:provider_name_required), do: "provider name is required"
  defp human_provider_error(:provider_base_url_required), do: "base URL is required"

  defp human_provider_error(:provider_base_url_must_be_http),
    do: "use an http:// or https:// URL"

  defp human_provider_error(reason), do: "could not save provider: #{human_error(reason)}"

  def redact_secrets(text) do
    text
    |> String.replace(~r/(?i)(bearer\s+)[^\s\"',}\]]+/, "\\1[REDACTED]")
    |> String.replace(
      ~r/(?i)((?:api[_-]?key|token|secret)[^:]{0,8}:\s*)\"[^\"]*\"/,
      "\\1\"[REDACTED]\""
    )
  end

  def model_id(%{id: id}), do: id
  def model_id(%{"id" => id}), do: id

  def model_label(model) do
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

  def human_error(term), do: Alto.Display.error(term, limit: 1_000)
end
