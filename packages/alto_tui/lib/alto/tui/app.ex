defmodule Alto.TUI.App do
  @moduledoc "Mouse-aware, multi-project terminal front end for the Alto coding harness."

  use ExRatatui.App

  alias Alto.Event
  alias Alto.Harness.{Catalog, ProviderProfile, ProviderStore}
  alias Alto.TUI.{Menu, Backend, Search, Selection, State, View, Attachments}
  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}

  @submission_selection [
    :selected_task_id,
    :selected_project_id,
    :selected_backend,
    :selected_provider_id,
    :selected_model,
    :approval_level,
    :approval_override?
  ]

  @approval_items [
    %{label: "ASK · prompt for each prepared mutation", value: :ask},
    %{label: "READ · deny prepared mutations", value: :read_only},
    %{label: "AUTO · approve prepared mutations", value: :full_access},
    %{label: "REVIEW · approve for me using configured agent/classifier", value: :review}
  ]

  @impl true
  def mount(opts) do
    with config when is_list(config) <- Keyword.get(opts, :config),
         {:ok, state} <- State.new(config, Keyword.put(opts, :async_history, true)) do
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
    pending? = Map.get(state, :stream_events, []) != []

    case do_handle_event(event, flush_stream(state)) do
      {:noreply, next, opts} when pending? -> {:noreply, next, Keyword.put(opts, :render?, true)}
      result -> result
    end
  end

  defp do_handle_event(event, state) do
    event = Alto.TUI.DragInput.latest(event, state.drag_poll)
    {width, height} = state.dimensions

    widgets = fn ->
      # Selection needs absolute history coordinates for dragging/autoscroll;
      # ordinary redraws only need the followed tail.
      selected =
        if state.transcript_follow? and match?(%Mouse{}, event) and
             View.hit_target(state, width, height, event.x, event.y) == :transcript,
           do: %{
             state
             | transcript_follow?: false,
               transcript_scroll: View.transcript_bottom_scroll(state)
           },
           else: state

      View.widgets(selected, %{width: width, height: height})
    end

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
             materialize: selection_materializer(state, width, height),
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

  defp selection_materializer(state, width, height) do
    rect = View.layout(state, width, height).transcript
    entries = State.visible_entries(state)
    # The persistent drag callback must not keep all tasks, child activity,
    # approvals and earlier selections reachable through the whole UI state.
    search = %State{
      textarea: nil,
      run_options: [],
      catalog_opts: [],
      entries: %{scratch: entries},
      search: state.search
    }

    fn {x, y}, offset, rows ->
      if x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height do
        if search.search,
          do: Search.highlighted(search, max(rect.width - 2, 1), offset, rows),
          else: Alto.TUI.Transcript.viewport(entries, max(rect.width - 2, 1), offset, rows)
      end
    end
  end

  defp route_event(%Key{kind: kind, code: "v", modifiers: ["ctrl"]}, state)
       when kind != "release" do
    case state.clipboard_read.() do
      {:ok, {:image, bytes, media}} ->
        if state.overlay == nil and state.search == nil,
          do: {:noreply, Attachments.paste_image(state, bytes, media)},
          else: {:noreply, %{state | notice: "Close the popup/search to paste an image"}}

      {:ok, text} when is_binary(text) ->
        route_event(%Paste{content: text}, state)

      _ ->
        if state.clipboard_text,
          do: route_event(%Paste{content: state.clipboard_text}, state),
          else: {:noreply, %{state | notice: "Paste with your terminal's paste shortcut"}}
    end
  end

  defp route_event(%Resize{width: width, height: height}, state),
    do:
      {:noreply,
       state
       |> Map.put(:dimensions, {width, height})
       |> State.reconcile_responsive_focus()
       |> View.reveal_search()}

  defp route_event(%Paste{content: content}, %{overlay: nil, search: search} = state)
       when not is_nil(search),
       do: {:noreply, state |> Search.paste(content) |> View.reveal_search()}

  defp route_event(%Paste{content: content}, %{overlay: nil, focus: :composer} = state) do
    {:noreply, Attachments.paste(state, content)}
  end

  defp route_event(%Paste{content: content}, %{overlay: %{kind: :attachment_editor}} = state),
    do: {:noreply, Attachments.editor_paste(state, content)}

  defp route_event(%Paste{content: content}, %{overlay: overlay} = state)
       when not is_nil(overlay),
       do: {:noreply, %{state | overlay: Menu.paste(overlay, content)}}

  defp route_event(%Paste{}, %{details_return_focus: focus} = state) when not is_nil(focus),
    do: {:noreply, state, render?: false}

  defp route_event(%Paste{content: content}, %{type_to_compose?: true} = state) do
    {:noreply, Attachments.paste(state, content)}
  end

  defp route_event(%Paste{}, state), do: {:noreply, state, render?: false}

  defp route_event(%Mouse{} = mouse, state), do: {:noreply, handle_mouse(state, mouse)}

  defp route_event(%Key{kind: "release"}, state), do: {:noreply, state, render?: false}

  defp route_event(%Key{} = key, %{overlay: overlay} = state) when not is_nil(overlay),
    do: {:noreply, overlay_key(state, key)}

  defp route_event(%Key{code: "f", modifiers: ["ctrl"]}, state),
    do: {:noreply, state |> Search.open() |> View.reveal_search()}

  defp route_event(%Key{code: "esc"}, %{search: search} = state) when not is_nil(search),
    do: {:noreply, Search.close(state)}

  defp route_event(
         %Key{code: "esc"},
         %{selected_agent_id: id, focus: :details, pending_approvals: []} = state
       )
       when not is_nil(id),
       do:
         {:noreply,
          %{state | selected_agent_id: nil, details_scroll: 0, details_drawer_auto_opened?: false}}

  defp route_event(%Key{code: "esc"}, %{details_return_focus: focus} = state)
       when not is_nil(focus),
       do: {:noreply, State.close_details_drawer(state)}

  defp route_event(%Key{code: "g", modifiers: ["ctrl"]}, state) do
    {:noreply, %{state | leader?: not state.leader?, notice: nil}}
  end

  defp route_event(%Key{} = key, %{leader?: true} = state) do
    case String.downcase(key.code || "") do
      "g" -> {:noreply, open_overlay(state, :goal)}
      "a" -> {:noreply, open_overlay(state, :approval)}
      "b" -> {:noreply, open_overlay(state, :backend)}
      "p" -> {:noreply, open_overlay(state, :provider)}
      "m" -> {:noreply, open_overlay(state, :model)}
      "r" -> {:noreply, open_overlay(state, :effort)}
      "e" -> {:noreply, toggle_composer_mode(state)}
      "f" -> {:noreply, Attachments.open(state)}
      "w" -> {:noreply, open_overlay(state, :project)}
      "x" -> {:noreply, State.close_workspace(state, state.selected_project_id)}
      "t" -> {:noreply, open_overlay(state, :task)}
      "n" -> {:noreply, state |> State.new_task() |> Map.put(:leader?, false)}
      "u" -> {:noreply, open_overlay(%{state | selected_agent_id: nil}, :agents)}
      "s" -> {:noreply, steer_queued(%{state | leader?: false})}
      "d" -> {:noreply, toggle_details(state)}
      "esc" -> {:noreply, %{state | leader?: false, notice: nil}}
      "q" -> {:stop, state}
      _other -> {:noreply, %{state | leader?: false, notice: "unknown gear key"}}
    end
  end

  defp route_event(%Key{code: "f2"}, state), do: {:noreply, open_overlay(state, :approval)}

  defp route_event(%Key{code: "f3"} = key, %{search: search} = state) when not is_nil(search),
    do: {:noreply, search_key(state, key)}

  defp route_event(%Key{code: "f3"}, state), do: {:noreply, open_overlay(state, :provider)}
  defp route_event(%Key{code: "f4"}, state), do: {:noreply, open_overlay(state, :model)}
  defp route_event(%Key{code: "f5"}, state), do: {:noreply, open_overlay(state, :backend)}
  defp route_event(%Key{code: "f6"}, state), do: {:noreply, toggle_composer_mode(state)}
  defp route_event(%Key{code: "f7"}, state), do: {:noreply, Attachments.open(state)}
  defp route_event(%Key{code: "f8"}, state), do: {:noreply, decide_approval(state, :approve)}

  defp route_event(%Key{code: "f9"}, state),
    do: {:noreply, decide_approval(state, {:deny, :user_denied})}

  defp route_event(%Key{} = key, %{search: search} = state) when not is_nil(search),
    do: {:noreply, search_key(state, key)}

  defp route_event(%Key{code: "tab"}, state), do: {:noreply, State.focus_next(state)}

  defp route_event(%Key{code: "back_tab"}, state),
    do: {:noreply, State.focus_next(state, :previous)}

  defp route_event(%Key{code: code, modifiers: modifiers}, state)
       when code == "esc" or (code == "c" and modifiers == ["ctrl"]) do
    case active_run(state) do
      nil ->
        {if(code == "c", do: :stop, else: :noreply), state}

      {_id, run} ->
        {:noreply, stop_active_run(state, run)}
    end
  end

  defp route_event(%Key{code: "enter", modifiers: modifiers} = key, %{focus: :composer} = state) do
    cond do
      "shift" in modifiers -> forward_textarea(state, key)
      "ctrl" in modifiers -> {:noreply, submit(state, :steer)}
      true -> {:noreply, submit(state)}
    end
  end

  defp route_event(
         %Key{code: "enter", modifiers: []},
         %{focus: focus, pending_approvals: []} = state
       )
       when focus in [:details, :transcript] do
    if not task_running?(state, state.selected_task_id) and
         (String.trim(ExRatatui.textarea_get_value(state.textarea)) != "" or
            State.input_pending?(state, state.selected_task_id)) do
      {:noreply, submit(state)}
    else
      {:noreply, %{state | notice: "Tab to the message composer to send a follow-up"}}
    end
  end

  defp route_event(%Key{} = key, %{focus: :composer} = state), do: forward_textarea(state, key)

  defp route_event(
         %Key{} = key,
         %{type_to_compose?: true, details_return_focus: nil} = state
       ) do
    if printable_key?(key) do
      forward_textarea(%{state | focus: :composer}, key)
    else
      {:noreply, navigate(state, key)}
    end
  end

  defp route_event(%Key{} = key, state), do: {:noreply, navigate(state, key)}

  @impl true
  def handle_info({:alto_tui_event, id, %Event{type: type} = event, sender, ref}, state)
      when type in [:model_delta, :model_reasoning_delta] do
    result = buffer_stream(state, id, event)
    send(sender, {ref, :ok})
    result
  end

  def handle_info({:alto_tui_event, id, %Event{type: type} = event}, state)
      when type in [:model_delta, :model_reasoning_delta],
      do: buffer_stream(state, id, event)

  def handle_info({:tui_stream_frame, token}, %{stream_frame: %{token: token}} = state),
    do: {:noreply, flush_stream(state)}

  def handle_info({:tui_stream_frame, _}, state), do: {:noreply, state, render?: false}

  def handle_info(message, state) do
    pending? = Map.get(state, :stream_events, []) != []
    result = do_handle_info(message, flush_stream(state))

    case result do
      {:noreply, next, opts} when pending? -> {:noreply, next, Keyword.put(opts, :render?, true)}
      other -> other
    end
  end

  defp buffer_stream(state, id, %Event{data: %{text: text}} = event) when is_binary(text) do
    if Map.has_key?(state.runs, id) do
      frame = state.stream_frame || new_stream_frame()

      state = %{
        state
        | stream_frame: frame,
          stream_bytes: state.stream_bytes + byte_size(text),
          stream_events: [{id, event} | state.stream_events]
      }

      if state.stream_bytes >= 8192 or length(state.stream_events) >= 256,
        do: {:noreply, flush_stream(state)},
        else: {:noreply, state, render?: false}
    else
      {:noreply, state, render?: false}
    end
  end

  defp buffer_stream(state, id, event),
    do: {:noreply, ingest_event(flush_stream(state), id, event)}

  defp new_stream_frame do
    token = make_ref()
    %{token: token, timer: Process.send_after(self(), {:tui_stream_frame, token}, 32)}
  end

  defp flush_stream(%{stream_frame: %{}} = state) do
    Process.cancel_timer(state.stream_frame.timer)
    events = Enum.reverse(state.stream_events)
    state = %{state | stream_frame: nil, stream_events: [], stream_bytes: 0}

    events
    |> Enum.chunk_by(fn {id, event} -> {id, event.type} end)
    |> Enum.reduce(state, fn [{id, event} | _] = chunk, acc ->
      text = Enum.map_join(chunk, fn {_, event} -> event.data.text end)
      ingest_event(acc, id, %{event | data: Map.put(event.data, :text, text)})
    end)
  end

  defp flush_stream(state), do: state

  defp do_handle_info({:tui_deferred_input, event}, state), do: handle_event(event, state)

  defp do_handle_info({:tui_history, token, kind, value}, state) do
    next = Alto.TUI.History.apply(state, token, kind, value)

    next =
      if (kind == :entries and next.history_load) && next.history_load.token == token do
        id = next.history_load.id
        if State.input_pending?(next, id), do: send(self(), {:alto_tui_send_input, id})
        if next.selected_task_id != id, do: State.hydrate_selected(next), else: next
      else
        next
      end

    {:noreply, next, render?: next != state}
  end

  defp do_handle_info(
         {:DOWN, monitor, :process, _pid, reason},
         %{history_load: %{monitor: monitor}} = state
       ) do
    id = state.history_load.id
    notice = if reason == :normal, do: state.notice, else: "Could not load saved history"
    next = %{state | history_load: nil, notice: notice}

    if reason != :normal and State.input_pending?(next, id),
      do: send(self(), {:alto_tui_send_input, id})

    next = if next.selected_task_id != id, do: State.hydrate_selected(next), else: next
    {:noreply, next}
  end

  defp do_handle_info(:tui_activity_tick, state) do
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

  defp do_handle_info({:tui_selection_scroll, token}, state) do
    case Selection.autoscroll(state.selection, token) do
      {:scrolled, selection} -> {:noreply, apply_selection_scroll(state, selection)}
      {:idle, selection} -> {:noreply, %{state | selection: selection}, render?: false}
    end
  end

  defp do_handle_info({:alto_tui_event, local_id, %Event{} = event, sender, ref}, state) do
    next = ingest_event(state, local_id, event)
    send(sender, {ref, :ok})
    {:noreply, next}
  end

  defp do_handle_info({:alto_tui_event, local_id, %Event{} = event}, state) do
    {:noreply, ingest_event(state, local_id, event)}
  end

  defp do_handle_info({:alto_approval_request, local_id, request, waiter}, state) do
    pending = %{
      local_id: local_id,
      request: request,
      respond: &send(waiter, {:alto_approval_decision, request.id, &1})
    }

    {:noreply, route_approval(state, pending)}
  end

  defp do_handle_info({:alto_approval_reviewed, id, decision}, state) do
    case Map.pop(state.approval_reviews, id) do
      {nil, _} ->
        {:noreply, state}

      {review, remaining} ->
        stop_review(review)
        review.pending.respond.(decision)
        {:noreply, %{state | approval_reviews: remaining, notice: approval_notice(decision)}}
    end
  end

  defp do_handle_info({:alto_models_loaded, profile_id, result}, state) do
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

  defp do_handle_info({:alto_tui_send_input, task_id}, state) do
    {:noreply, send_input(state, task_id)}
  end

  # Completion is a runner notification, independent of its implementation.
  defp do_handle_info({:alto_runner_result, ref, result}, state) when is_reference(ref) do
    case Enum.find(state.runs, fn {_id, run} -> run[:ref] == ref end) do
      nil -> {:noreply, state, render?: false}
      {local_id, _run} -> {:noreply, finish_runner_result(state, local_id, result)}
    end
  end

  defp do_handle_info(
         {:alto_worktree_created, token, result},
         %{worktree_creation: %{token: token} = pending} = state
       ) do
    Process.demonitor(pending.monitor, [:flush])
    visible? = state.overlay && state.overlay.kind == :worktree_creating
    state = %{state | worktree_creation: nil}

    case result do
      {:ok, result} ->
        if visible? do
          {:noreply, form_result(%{state | overlay: pending.form}, {:submit, result["cwd"]})}
        else
          state =
            case Alto.Harness.Catalog.navigation(state.catalog_opts) do
              {:ok, projects, tasks} -> %{state | projects: projects, tasks: tasks}
              _ -> state
            end

          {:noreply, %{state | notice: "Worktree created: " <> result["cwd"]}}
        end

      {:error, reason} ->
        error = "Could not create worktree: #{Alto.Display.error(reason)}"

        {:noreply,
         if(visible?,
           do: %{state | overlay: %{pending.form | error: error}},
           else: %{state | notice: error}
         )}
    end
  end

  defp do_handle_info(
         {:DOWN, monitor, :process, _pid, reason},
         %{worktree_creation: %{monitor: monitor} = pending} = state
       ),
       do:
         handle_info(
           {:alto_worktree_created, pending.token, {:error, {:creation_exited, reason}}},
           state
         )

  defp do_handle_info(:prepare_backend, state), do: {:noreply, backend_action(state, :prepare)}

  defp do_handle_info(message, state) do
    case Backend.message(state, message) do
      :pass -> {:noreply, state, render?: false}
      result -> result
    end
  end

  @impl true
  def terminate(_reason, state) do
    Alto.TUI.History.stop(state)
    Enum.each(state.approval_reviews, fn {_, review} -> stop_review(review) end)
    Enum.each(state.runs, fn {_id, run} -> cancel_run(run) end)
    :ok
  end

  defp submit(state, mode \\ :follow_up) do
    text = state.textarea |> ExRatatui.textarea_get_value() |> String.trim()

    case Attachments.prepare(state, text) do
      {:ok, prompt} ->
        submit_prompt(state, prompt, mode)

      {:error, reason} ->
        %{state | notice: "Cannot attach files: #{human_error(reason)} · draft kept"}
    end
  end

  defp submit_prompt(state, prompt, mode) do
    cond do
      state.selected_project_id == nil ->
        %{state | notice: "Open a workspace first · ^G W"}

      prompt == "" and mode == :steer and task_running?(state, state.selected_task_id) ->
        steer_queued(state)

      prompt == "" and not task_running?(state, state.selected_task_id) and
          State.input_pending?(state, state.selected_task_id) ->
        send_input(state, state.selected_task_id)

      prompt == "" ->
        %{state | notice: "write a message first"}

      Alto.TUI.History.loading_entries?(state, state.selected_task_id) ->
        queue_input(state, state.selected_task_id, prompt, :follow_up)

      task_running?(state, state.selected_task_id) ->
        queue_message(state, prompt, mode)

      map_size(state.runs) >= 32 ->
        %{state | notice: "too many active runs; finish or cancel one first"}

      true ->
        submit_backend(state, prompt)
    end
  end

  defp steer_queued(state) do
    cond do
      not task_running?(state, state.selected_task_id) ->
        %{state | notice: "No running task to steer · Enter sends queued input"}

      Backend.ui(state, :steering?) != true ->
        %{state | notice: "This backend cannot steer · queued message kept"}

      true ->
        input = Map.get(state.inputs, state.selected_task_id)

        result =
          if input,
            do: Alto.Input.request(input, :steer_next),
            else: {:error, :no_queued_follow_up}

        case result do
          :ok ->
            %{state | notice: "Queued message will steer at the next safe boundary"}

          {:error, :no_queued_follow_up} ->
            %{state | notice: "No queued follow-up to steer"}

          {:error, reason} ->
            %{state | notice: "Cannot steer queued message: #{human_error(reason)}"}
        end
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
         {:ok, _input_id} <-
           Alto.Messaging.send(input, Attachments.message_options(prompt) ++ [delivery: mode]) do
      ExRatatui.textarea_set_value(state.textarea, "")

      state
      |> Map.update!(
        :input_routes,
        &Map.put_new_lazy(&1, task_id, fn ->
          %{selection: Map.take(state, @submission_selection)}
        end)
      )
      |> Map.put(:attachments, [])
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
    if Enum.any?(Alto.Input.request(input, :list), &(&1.mode == :follow_up)),
      do: {:error, :follow_up_pending},
      else: :ok
  end

  defp input_notice(:steer), do: "steering message accepted · Enter queues a follow-up"
  defp input_notice(:follow_up), do: "message queued · ^G S steer queued · Esc stops current run"

  defp input_route_available(state, task_id) do
    if Map.has_key?(state.input_routes, task_id) or map_size(state.input_routes) < 32,
      do: :ok,
      else: {:error, :pending_task_capacity}
  end

  defp ensure_input(state, task_id) do
    case Map.get(state.inputs, task_id) do
      input when not is_nil(input) ->
        {:ok, state}

      nil ->
        case Alto.Input.open(
               transport: state.run_options[:messaging_transport],
               max_bytes: 16_000_000,
               id: "task-" <> task_id
             ) do
          {:ok, input} -> {:ok, put_in(state.inputs[task_id], input)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp send_input(%{history_load: %{id: task_id}, entries: entries} = state, task_id)
       when not is_map_key(entries, task_id),
       do: state

  defp send_input(state, task_id) do
    case {task_running?(state, task_id), Map.get(state.inputs, task_id)} do
      {false, input} when not is_nil(input) and map_size(state.runs) < 32 ->
        case Alto.Input.request(input, {:take, :user}) do
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
            draft_attachments = state.attachments

            next =
              state
              |> Map.merge(Map.get(route, :selection, %{}))
              |> submit_backend(
                if(entry[:content], do: Alto.Content.new(entry.content), else: entry.text)
              )

            ExRatatui.textarea_set_value(state.textarea, draft)
            next = next |> Map.merge(foreground) |> Map.put(:attachments, draft_attachments)

            if task_running?(next, task_id) do
              clear_input_route(next, task_id)
            else
              case Alto.Messaging.send(input,
                     text: entry.text,
                     delivery: entry.mode,
                     in_reply_to: entry[:in_reply_to],
                     content: entry[:content]
                   ) do
                {:ok, _receipt} ->
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

  defp finish_queued(state, task_id, continue?) do
    if State.input_pending?(state, task_id) do
      if continue?, do: send(self(), {:alto_tui_send_input, task_id})
      notice = if continue?, do: "input retained", else: "queued message paused"
      %{state | notice: state.notice <> " · #{notice} (Enter sends)"}
    else
      state
    end
  end

  defp clear_input_route(state, task_id) do
    if State.input_pending?(state, task_id),
      do: state,
      else: %{state | input_routes: Map.delete(state.input_routes, task_id)}
  end

  defp stop_active_run(state, run) do
    cancel_run(run)

    state
    |> clear_approvals(&(Map.get(&1, :local_id) == run.local_id))
    |> update_run(run, phase: "cancelling")
    |> Map.put(:notice, "cancelling run · draft and queued message kept")
  end

  defp submit_backend(state, prompt) do
    with :pass <- Backend.ui(state, {:submit, prompt}), do: submit_runner(state, prompt)
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
             {:ok, state} <- ensure_input(state, task["id"]),
             {:ok, run_options} <- run_options(state, profile),
             :ok <- Attachments.validate_provider(prompt, run_options[:provider]),
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
              started_at_ms: System.system_time(:millisecond)
            },
            prompt,
            "run started"
          )
        else
          {:error, reason} ->
            message = "Cannot continue: #{human_error(reason)}"

            state
            |> State.append_entry(state.selected_task_id, %{kind: :error, text: message})
            |> Map.put(:notice, message <> " · draft kept")
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
        %{approval_sink: owner, approval_route: local_id},
        &Map.merge(&1, %{approval_sink: owner, approval_route: local_id})
      )

    with {:ok, handle} <-
           do_start_task(task, Alto.TUI.Goal.with_context(task, prompt), run_options) do
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
    |> State.append_entry(run.task_id, %{kind: :user, text: Attachments.summary(prompt)})
    |> Map.update!(:runs, &Map.put(&1, local_id, Map.put(run, :local_id, local_id)))
    |> Map.put(:notice, notice)
    |> Map.put(:attachments, [])
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
    title =
      prompt
      |> Attachments.summary()
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.slice(0, 96)

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
          :tui,
          :listeners,
          :queue,
          :runs,
          :sessions
        ])
        |> Keyword.put(:provider_profiles, state.profiles)
        |> Keyword.put(:credentials_path, state.credentials_path)
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
    configured = Keyword.get(state.run_options, :approval)

    if state.approval_override? or is_nil(configured) or
         configured == (&Alto.Approval.interactive/2) do
      &Alto.Approval.delegated/2
    else
      configured
    end
  end

  def route_approval(state, pending) do
    reviewer = state.run_options |> Keyword.get(:tui, []) |> Keyword.get(:approval_reviewer)

    decision =
      case state.approval_level do
        :full_access -> :approve
        :read_only -> {:deny, :read_only_mode}
        :review when is_function(reviewer, 2) -> {:review, reviewer}
        _ -> :ask
      end

    cond do
      decision == :ask ->
        show_pending_approval(state, pending, "approval required · F8 approve / F9 deny")

      match?({:review, _}, decision) and Map.has_key?(pending, :review_context) ->
        start_approval_review(state, pending, reviewer)

      true ->
        pending.respond.(decision)
        state
    end
  end

  defp start_approval_review(state, pending, reviewer) do
    owner = self()
    id = pending.request.id

    {:ok, pid} =
      Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
        decision =
          try do
            case Alto.Approval.review(reviewer, pending.request, pending.review_context) do
              :approve -> :approve
              {:deny, _} = deny -> deny
              _ -> {:deny, :invalid_reviewer_decision}
            end
          rescue
            _ -> {:deny, :reviewer_failed}
          catch
            _, _ -> {:deny, :reviewer_failed}
          end

        send(owner, {:alto_approval_reviewed, id, decision})
      end)

    timer =
      Process.send_after(
        owner,
        {:alto_approval_reviewed, id, {:deny, :reviewer_timeout}},
        Keyword.get(state.run_options, :approval_timeout, 300_000)
      )

    review = %{pid: pid, timer: timer, pending: pending}

    %{
      state
      | approval_reviews: Map.put(state.approval_reviews, id, review),
        notice: "reviewing approval"
    }
  end

  defp stop_review(review) do
    Process.cancel_timer(review.timer)
    Process.exit(review.pid, :kill)
  end

  defp runtime_provider(state, profile) do
    {module, options} =
      ProviderProfile.runtime_provider(profile, state.selected_model,
        credentials_path: state.credentials_path
      )

    options = maybe_context_window(options, State.model_metadata(state))

    options =
      if effort = State.selected_effort(state),
        do: Keyword.put(options, :reasoning_effort, effort),
        else: options

    {module, options}
  end

  defp maybe_context_window(options, %{context_window: value})
       when is_integer(value) and value > 0,
       do: Keyword.put_new(options, :context_window, value)

  defp maybe_context_window(options, %{context_length: value})
       when is_integer(value) and value > 0,
       do: Keyword.put_new(options, :context_window, value)

  defp maybe_context_window(options, _metadata), do: options

  defp finish_runner_result(state, local_id, result) do
    completed? = result.status == :ok
    status = if completed?, do: "completed", else: "failed"

    {entry, notice} =
      case result.status do
        :ok ->
          {nil, "run completed"}

        :cancelled ->
          message =
            if result.reason == :user,
              do: "Run cancelled by user",
              else: "Run cancelled: #{human_error(result.reason)}"

          {%{kind: :system, text: message}, "run cancelled · Enter sends a follow-up"}

        _ ->
          {%{kind: :error, text: human_error(result.reason)}, "run failed"}
      end

    persistence = result.persistence

    {entry, notice} = persistence_feedback(entry, notice, persistence)

    finish_run(state, local_id, status,
      session_id: result.session_id,
      entry: entry,
      notice: notice,
      continue?: status == "completed" and not match?({:degraded, _}, persistence)
    )
  end

  def finish_run(state, local_id, status, opts \\ []) do
    run = Map.fetch!(state.runs, local_id)
    Alto.Runner.release(run[:handle])
    changes = %{"status" => status} |> maybe_change("conversation_id", opts[:session_id])

    state = State.update_task(state, run.task_id, changes)

    state = if opts[:entry], do: State.append_entry(state, run.task_id, opts[:entry]), else: state

    state
    |> drop_run(local_id)
    |> Map.put(:notice, opts[:notice])
    |> finish_queued(run.task_id, Keyword.get(opts, :continue?, status == "completed"))
  end

  def update_run(state, local_id, changes) when is_binary(local_id) do
    update_in(state.runs[local_id], &Map.merge(&1, Map.new(changes)))
  end

  def update_run(state, %{local_id: id}, changes), do: update_run(state, id, changes)

  def sync_run_task(state, run) do
    changes =
      %{"status" => "active"}
      |> maybe_change("backend", run[:backend_id] && Atom.to_string(run.backend_id))
      |> maybe_change("conversation_id", run[:thread_id])

    State.update_task(state, run.task_id, changes)
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
        phase = Alto.TUI.Activity.phase(event, Map.get(run, :phase, "working"))
        run = if run[:phase] == "cancelling", do: run, else: Map.put(run, :phase, phase)
        state = put_in(state.runs[local_id], run)
        do_ingest_event(state, run.task_id, event)
    end
  end

  defp clear_approvals(state, predicate) do
    {expired, active} =
      Enum.split_with(state.approval_reviews, fn {_, review} -> predicate.(review.pending) end)

    Enum.each(expired, fn {_, review} -> stop_review(review) end)
    state = %{state | approval_reviews: Map.new(active)}
    pending = Enum.reject(state.pending_approvals, predicate)
    state = if pending != state.pending_approvals, do: Search.close(state), else: state
    state = reset_approval_view(state, pending)

    if pending == [] and state.details_drawer_auto_opened?,
      do: State.close_details_drawer(state),
      else: state
  end

  defp do_ingest_event(state, task_id, %Event{type: type} = event)
       when type in [:subagent_status, :subagent_progress] do
    state = Alto.TUI.Subagents.ingest(state, task_id, event)

    if task_id == state.selected_task_id and match?(%{kind: :agents}, state.overlay) do
      selected = Menu.selected(state.overlay)
      {:ok, _, items, _} = overlay_items(state, :agents)
      menu = %{state.overlay | items: items}

      index =
        Enum.find_index(Menu.items(menu), &(&1[:value] == (selected && selected[:value]))) || 0

      %{state | overlay: %{menu | index: index}}
    else
      state
    end
  end

  defp do_ingest_event(state, _task_id, %Event{
         type: :approval_resolved,
         data: %{request: request}
       }),
       do: clear_approvals(state, &(&1.request.id == request.id))

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
    state = State.update_usage(state, task_id, Map.get(data, :usage, %{}))

    state =
      if is_list(data[:message]) do
        text =
          for(%{"type" => "text", "text" => text} <- data.message, do: text) |> Enum.join("\n")

        last = State.current_entries(%{state | selected_task_id: task_id}) |> List.last()

        cond do
          text == "" -> state
          last && last.kind == :assistant -> state
          true -> State.append_entry(state, task_id, %{kind: :assistant, text: text})
        end
      else
        state
      end

    Attachments.outputs(state, task_id, data[:message])
  end

  defp do_ingest_event(state, task_id, %Event{type: type, data: data})
       when type in [:tool_started, :tool_completed, :tool_failed] do
    entry = Alto.ToolDisplay.entry(type, data)
    key = {:tool, data[:operation_id] || data[:call_id]}
    state = State.upsert_entry(state, task_id, key, entry)

    if type == :tool_completed and match?(%Alto.Content{}, data[:value]),
      do: Attachments.outputs(state, task_id, data[:value]),
      else: state
  end

  defp do_ingest_event(state, task_id, %Event{
         type: :context_compacted,
         data: %{strategy: :handoff, artifact_path: path, next_step: next}
       }) do
    State.append_entry(state, task_id, %{
      kind: :system,
      text: "handoff created\n#{path}\nnext: #{next}"
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

  defp overlay_items(state, :goal), do: {:state, Alto.TUI.Goal.open(state)}

  defp overlay_items(state, :agents) do
    items =
      Enum.map(Alto.TUI.Subagents.list(state), fn agent ->
        %{
          label: Alto.TUI.Subagents.label(agent) <> " · " <> agent.agent_id,
          value: {:agent, agent.agent_id}
        }
      end)

    if items == [],
      do: {:error, "No subagent activity for this task yet"},
      else: {:ok, "subagents · select to view activity and results", items, nil}
  end

  defp overlay_items(state, :effort) do
    case State.effort_choices(state) do
      [] ->
        profile = State.selected_profile(state)

        if profile && not is_list(State.known_models(state, profile)) &&
             not MapSet.member?(state.model_loading, profile.id),
           do: {:load, profile},
           else: {:error, "This model does not advertise effort selection"}

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
        case State.known_models(state, profile) do
          models when is_list(models) ->
            items = Enum.map(models, &%{label: model_label(&1), value: &1.id})
            {:ok, "models · type to filter", items, state.selected_model}

          _ ->
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
          do: [
            %{label: "Create worktree…", value: :new_worktree},
            %{label: "Close workspace · ^G X", value: :close_workspace}
          ],
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

  defp overlay_key(%{overlay: %{kind: :workspace_form}} = state, %Key{
         code: "n",
         modifiers: ["ctrl"]
       }),
       do: form_result(state, :create)

  defp overlay_key(%{overlay: %{kind: :workspace_form}} = state, %Key{
         code: "o",
         modifiers: ["ctrl"]
       }),
       do: form_result(state, :choose)

  defp overlay_key(%{overlay: %{kind: :attachment_editor}} = state, key),
    do: Attachments.editor_key(state, key)

  defp overlay_key(state, key) do
    case Menu.key(state.overlay, key) do
      :cancel -> close_overlay(state)
      :select -> select_overlay(state)
      {:action, action} -> action.(state)
      {:edit, overlay} -> %{state | overlay: overlay}
    end
  end

  defp select_overlay(%{overlay: overlay} = state) do
    case Enum.at(Menu.items(overlay), overlay.index) do
      nil ->
        state

      %{input: _} ->
        state

      %{action: action} ->
        action.(state)

      %{value: nil} ->
        state

      %{value: {:select_backend, backend}} ->
        select_backend(state, backend)

      %{value: {:folder, path}} ->
        form = state.overlay.return_form
        ExRatatui.text_input_set_value(Menu.field(form, :path).input, path)
        ExRatatui.text_input_handle_key(Menu.field(form, :path).input, "end")
        %{state | overlay: Menu.refresh_folder(%{form | index: 0, error: nil})}

      %{value: :new_workspace} ->
        open_workspace_form(state)

      %{value: :new_worktree} ->
        open_worktree_form(state)

      %{value: :close_workspace} ->
        State.close_workspace(state, state.selected_project_id)

      %{value: {:agent, id}} ->
        next = %{
          state
          | selected_agent_id: id,
            overlay: nil,
            details_visible?: true,
            details_scroll: 0
        }

        if State.details_pane_visible?(next),
          do: %{next | focus: :details},
          else: State.open_details_drawer(next)

      %{value: :new_task} ->
        State.new_task(state)

      %{value: {:configure_provider, profile_id}} ->
        open_provider_form(state, profile_id)

      %{value: {:retry_models, profile_id}} ->
        retry_models(state, profile_id)

      %{value: {:enter_model, profile_id}} ->
        open_model_form(state, profile_id)

      %{value: value} ->
        selected =
          with :pass <- Backend.ui(state, {:select, value}),
               do: apply_selection(state, state.overlay.kind, value)

        if state.overlay.kind in [:model, :model_error, :provider, :backend],
          do: State.remember_selection(selected),
          else: selected
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

  defp apply_selection(state, :approval, value) do
    reviewer = state.run_options |> Keyword.get(:tui, []) |> Keyword.get(:approval_reviewer)

    if value == :review and not is_function(reviewer, 2) do
      %{state | notice: "Configure tui: [approval_reviewer: &YourReviewer.review/2] first"}
    else
      next = %{
        state
        | approval_level: value,
          approval_override?: true,
          overlay: nil,
          notice: "approval level: #{value}"
      }

      if value == :ask do
        next
      else
        resolved =
          Enum.reduce(
            next.pending_approvals,
            reset_approval_view(next, []),
            &route_approval(&2, &1)
          )

        %{resolved | details_drawer_auto_opened?: false}
      end
    end
  end

  defp apply_selection(state, :provider, value) do
    profile = Enum.find(state.profiles, &(&1.id == value))

    %{
      state
      | selected_provider_id: value,
        selected_model: profile.default_model,
        overlay: nil,
        notice: "provider: #{profile.label}"
    }
    |> State.restore_model()
  end

  defp apply_selection(state, :model_error, value), do: apply_selection(state, :model, value)

  defp apply_selection(state, :model, value),
    do: %{state | selected_model: value, overlay: nil, notice: "model: #{value}"}

  defp apply_selection(state, kind, value) when kind in [:project, :task] do
    {selected, notice} =
      case kind do
        :project -> {State.select_project(state, value), "workspace switched"}
        :task -> {State.select_task(state, value), "task switched"}
      end

    selected
    |> backend_action(:prepare)
    |> Map.merge(%{overlay: nil, notice: notice})
  end

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
      {:search_result, _} -> search_move(state, delta)
      :search_results -> search_move(state, delta)
      _other -> state
    end
  end

  defp handle_mouse(state, _mouse), do: state

  defp activate_target(state, :search_prev, _x), do: search_move(state, -1)
  defp activate_target(state, :search_next, _x), do: search_move(state, 1)
  defp activate_target(state, :search_close, _x), do: Search.close(state)

  defp activate_target(state, {:search_result, index}, _x),
    do:
      state
      |> Search.select(index)
      |> State.close_details_drawer()
      |> Map.put(:focus, :transcript)
      |> View.reveal_search()

  defp activate_target(state, seam, _x) when seam in [:left_seam, :right_seam],
    do: %{state | dragging: seam}

  defp activate_target(state, :new_workspace, _x), do: open_workspace_form(state)
  defp activate_target(state, {:close_workspace, id}, _x), do: State.close_workspace(state, id)

  defp activate_target(state, {:rail_row, row}, _x) do
    selected = state |> State.select_rail_row(row) |> backend_action(:prepare)

    case row do
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
    do: decide_approval(%{state | focus: :details}, approval_decision(decision))

  defp activate_target(%{overlay: form} = state, {:folder_suggestion, index}, _x),
    do: %{state | overlay: Menu.complete_folder(form, Enum.at(form.suggestions, index))}

  defp activate_target(state, {:overlay_row, row}, _x), do: handle_overlay_click(state, row)
  defp activate_target(state, :overlay_outside, _x), do: close_overlay(state)
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

  defp search_key(state, %Key{code: code, modifiers: modifiers}) do
    cond do
      code in ["tab", "back_tab"] ->
        cond do
          State.details_pane_visible?(state) ->
            %{state | focus: if(state.focus == :details, do: :transcript, else: :details)}

          state.details_return_focus ->
            State.close_details_drawer(state)

          true ->
            State.open_details_drawer(state)
        end

      code in ["enter", "f3"] ->
        search_move(state, if("shift" in modifiers, do: -1, else: 1))

      code == "down" ->
        search_move(state, 1)

      code == "up" ->
        search_move(state, -1)

      code == "u" and modifiers == ["ctrl"] ->
        state |> Search.edit(:clear) |> View.reveal_search()

      Enum.all?(modifiers, &(&1 == "shift")) and
          (String.length(code || "") == 1 or code in ~w(backspace delete left right home end)) ->
        state |> Search.edit(code) |> View.reveal_search()

      true ->
        state
    end
  end

  defp search_move(state, delta), do: state |> Search.move(delta) |> View.reveal_search()

  defp printable_key?(%Key{code: code, modifiers: modifiers}) when is_binary(code) do
    String.length(code) == 1 and Enum.all?(modifiers, &(&1 == "shift"))
  end

  defp printable_key?(_key), do: false

  defp toggle_details(%{search: search} = state) when not is_nil(search),
    do: search_key(%{state | leader?: false}, %Key{code: "tab"})

  defp toggle_details(state) do
    state = %{state | leader?: false}

    cond do
      state.details_return_focus ->
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
    state |> State.select_rail_row(Enum.at(rows, index)) |> backend_action(:prepare)
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

    state = Search.close(state)

    %{
      reset_approval_view(state, rest)
      | notice: approval_notice(decision),
        details_drawer_auto_opened?: false
    }
  end

  def show_pending_approval(state, pending, notice) do
    state = Search.close(state)

    next = %{
      reset_approval_view(state, state.pending_approvals ++ [pending])
      | details_visible?: true,
        notice: notice
    }

    cond do
      not next.approval_auto_open? ->
        State.ensure_visible_focus(next)

      State.details_pane_visible?(next) or next.details_return_focus ->
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

  def drop_run(state, local_id) do
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

    message = human_error(reason)

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
          Menu.form(
            :provider_form,
            if(new?, do: "add provider", else: "configure #{profile.label}"),
            fields,
            on_action: &form_result/2,
            intro: "Credentials are saved privately outside the workspace.",
            hint: "Tab/↑↓ fields · Enter next/save · ^S save · Esc",
            buttons: ["[ Save provider ]", "[ Cancel ]"],
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
      | overlay:
          Menu.form(
            :workspace_form,
            "Open folder",
            [{:path, "Folder", "", [placeholder: "/path/to/project"]}],
            base: base,
            folders: Enum.map(state.projects, &(String.trim_trailing(&1["root"], "/") <> "/")),
            on_action: &form_result/2,
            intro: "Relative paths start from: #{base}",
            hint: "↑↓ choose · Tab complete · Ctrl+O choose · Ctrl+N create · Esc cancel",
            buttons: ["[ Open folder ]", "[ Cancel ]", "[ Choose folder ]", "[ Create folder ]"],
            actions: [:submit, :cancel, :choose, :create]
          ),
        leader?: false
    }
  end

  defp open_worktree_form(%{worktree_creation: pending} = state) when not is_nil(pending),
    do: %{state | notice: "A worktree is already being created"}

  defp open_worktree_form(state) do
    project = State.selected_project(state)

    %{
      state
      | leader?: false,
        overlay:
          Menu.form(
            :worktree_form,
            "Create local worktree",
            [
              {:name, "Name", "", []},
              {:ref, "Start ref", "HEAD", []},
              {:branch, "New branch", "", []}
            ],
            on_action: &form_result/2,
            intro: "#{project["root"]} · committed files only",
            hint: "Tab next · Ctrl+S create · Esc cancel",
            buttons: ["[ Create & open ]", "[ Cancel ]"],
            source: project["root"]
          )
    }
  end

  defp open_model_form(state, profile_id) do
    %{
      state
      | selected_provider_id: profile_id,
        overlay:
          Menu.form(
            :model_form,
            "exact model ID",
            [{:model, "Model ID", "", []}],
            on_action: &form_result/2,
            intro: "Use the provider's exact model identifier.",
            hint: "Enter use · Esc",
            buttons: ["[ Use model ]", "[ Cancel ]"],
            profile_id: profile_id
          )
    }
  end

  defp close_overlay(state), do: %{state | overlay: Map.get(state.overlay, :return_form)}

  defp form_result(state, :cancel), do: close_overlay(state)

  defp form_result(%{overlay: %{kind: :workspace_form} = form} = state, :choose) do
    path = Menu.value(form, :path)

    saved =
      if path == "",
        do: Enum.map(state.projects, &(String.trim_trailing(&1["root"], "/") <> "/")),
        else: []

    found =
      case Alto.Harness.Folders.suggest(path, form.base) do
        {:ok, %{folders: folders}} -> folders
        _ -> []
      end

    items =
      Enum.map(Enum.take(Enum.uniq(saved ++ found), 50), &%{label: &1, value: {:folder, &1}})

    %{
      state
      | overlay:
          Map.put(Menu.new(:folder, "Choose folder · type to filter", items), :return_form, form)
    }
  end

  defp form_result(%{overlay: %{kind: :workspace_form} = form} = state, :create),
    do: form_result(state, {:create, Menu.value(form, :path)})

  defp form_result(%{overlay: %{kind: :workspace_form} = form} = state, :submit),
    do: form_result(state, {:submit, Menu.value(form, :path)})

  defp form_result(state, {:create, path}) do
    case Alto.Harness.Folders.create(path, state.overlay.base) do
      {:ok, root} -> form_result(state, {:submit, root})
      {:error, reason} -> put_in(state.overlay.error, Alto.Display.error(reason))
    end
  end

  defp form_result(state, {:submit, path}) do
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

  defp form_result(%{overlay: %{kind: :worktree_form} = form} = state, :submit) do
    values = Menu.values(form)
    args = %{"name" => String.trim(values.name), "ref" => String.trim(values.ref)}

    args =
      if String.trim(values.branch) == "",
        do: args,
        else: Map.put(args, "branch", String.trim(values.branch))

    owner = self()
    token = make_ref()

    {_pid, monitor} =
      spawn_monitor(fn ->
        send(
          owner,
          {:alto_worktree_created, token,
           Alto.Harness.Worktrees.create(form.source, args, state.catalog_opts)}
        )
      end)

    %{
      state
      | worktree_creation: %{token: token, monitor: monitor, form: form},
        overlay:
          Menu.new(:worktree_creating, "Creating worktree…", [
            %{label: "Esc returns to your task; creation continues", value: nil}
          ])
    }
  end

  defp form_result(%{overlay: %{kind: :provider_form}} = state, :submit),
    do: save_provider_form(state)

  defp form_result(%{overlay: %{kind: :model_form} = form} = state, :submit) do
    model = form |> Menu.value(:model) |> String.trim()

    if model == "",
      do: put_in(state.overlay.error, "model ID is required"),
      else: state |> apply_selection(:model, model) |> State.remember_selection()
  end

  defp save_provider_form(state) do
    attrs = Menu.values(state.overlay)

    api_key_field = Menu.field(state.overlay, :api_key)

    case ProviderStore.save(attrs, state.profiles, credentials_opts(state)) do
      {:ok, profiles} ->
        # Clear the opaque native input before releasing the form reference.
        ExRatatui.text_input_set_value(api_key_field.input, "")

        profile = Enum.find(profiles, &(&1.id == String.trim(attrs.id)))

        next = %{
          state
          | profiles: profiles,
            selected_provider_id: profile.id,
            selected_model: profile.default_model,
            models: Map.delete(state.models, profile.id),
            overlay: nil,
            notice: "provider saved"
        }

        previous = Enum.find(state.profiles, &(&1.id == profile.id))

        # Changing the default model explicitly selects it. Credential and label
        # edits preserve the current choice, or restore this provider's choice.
        next =
          cond do
            previous && previous.default_model != profile.default_model ->
              next

            state.selected_provider_id == profile.id ->
              %{next | selected_model: state.selected_model || profile.default_model}

            true ->
              State.restore_model(next)
          end

        next = State.remember_selection(next)
        if state.overlay.after_save == :model, do: open_overlay(next, :model), else: next

      {:error, reason} ->
        put_in(state.overlay.error, human_provider_error(reason))
    end
  end

  defp handle_overlay_click(state, index),
    do: state |> put_overlay_index(index) |> select_overlay()

  defp select_backend(state, backend) when is_atom(backend) do
    task = State.selected_task(state)

    cond do
      backend not in Enum.map(Backend.items(state.run_options), & &1.value) ->
        %{state | notice: "backend is not configured"}

      state.selected_backend == backend ->
        backend_action(%{state | overlay: nil}, :selected)

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
        next = state |> State.sync_backend(backend) |> Map.put(:overlay, nil)

        backend_action(%{next | notice: "backend: #{backend}"}, :selected)
    end
  end

  defp task_backend_locked?(nil), do: false

  defp task_backend_locked?(task),
    do: is_binary(task["conversation_id"])

  defp persist_task_backend(state, nil, _backend), do: state

  defp persist_task_backend(state, task, backend),
    do: State.update_task(state, task["id"], %{"backend" => Atom.to_string(backend)})

  defp backend_action(state, action) do
    with :pass <- Backend.ui(state, action), do: state
  end

  defp credentials_opts(state), do: [credentials_path: state.credentials_path]

  defp human_provider_error(:provider_id_must_be_lowercase_slug),
    do: "ID must use lowercase letters, numbers, dots, dashes, or underscores"

  defp human_provider_error(:provider_name_required), do: "provider name is required"
  defp human_provider_error(:provider_base_url_required), do: "base URL is required"

  defp human_provider_error(:provider_base_url_must_be_http),
    do: "use an http:// or https:// URL"

  defp human_provider_error(reason), do: "could not save provider: #{human_error(reason)}"

  def model_label(%{id: id} = model) do
    name = model[:name] || id
    context = model[:context_length]
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
