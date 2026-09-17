defmodule Alto.TUI.Backends.Codex do
  @moduledoc "Codex account, protocol, approval and interactive lifecycle contributions."
  @behaviour Alto.TUI.Backend
  alias Alto.Codex.AppServer.Client, as: CodexClient
  alias Alto.Codex.Backend, as: CodexBackend
  alias Alto.Harness.Catalog
  alias Alto.TUI.State
  alias Alto.TUI.App, as: Host

  @codex_approval_items [
    %{label: "ASK · workspace sandbox; prompt for escalations", value: :ask},
    %{label: "READ · read-only sandbox; no escalation", value: :read_only},
    %{label: "AUTO · full host access; no prompts", value: :full_access}
  ]

  @impl true
  def ui(:init, state, options) do
    codex_options =
      Keyword.merge(
        Keyword.get(state.run_options, :codex_backend, []),
        Keyword.delete(options, :label)
      )

    codex = %{
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
    }

    model =
      if selected?(state),
        do: Keyword.get(codex_options, :model),
        else: state.selected_model

    %{state | codex: codex, selected_model: model}
  end

  def ui(:provider_label, state, _options), do: CodexBackend.account_label(state.codex.account)
  def ui(:context_window, state, _options), do: state.codex.context_window

  def ui(:quota_label, state, _options) do
    case CodexBackend.primary_rate_limit(state.codex.rate_limits) do
      %{"usedPercent" => used} when is_number(used) -> "  quota #{Float.round(used * 1.0, 1)}%"
      _ -> "  quota —"
    end
  end

  def ui(:models, state, _options), do: state.codex.models

  def ui(:activity, %{codex: %{status: status}}, _options)
      when status in [:connecting, :refreshing],
      do: "waiting for Codex connection"

  def ui(:sync_model, state, _options) do
    if Enum.any?(state.codex.models, &((&1[:id] || &1["id"]) == state.selected_model)),
      do: state.selected_model,
      else: backend_model(state)
  end

  def ui({:message, message}, state, _options), do: handle_info(message, state)
  def ui({:submit, prompt}, state, _options), do: submit_codex(state, prompt)
  def ui(:model, state, _options), do: backend_model(state)
  def ui(:selected, state, _options), do: ensure_codex(state, true)

  def ui(:prepare, state, _options) do
    if state.codex.status == :ready and is_pid(state.codex.client),
      do: maybe_load_codex_history(state),
      else: ensure_codex(state, false)
  end

  def ui({:overlay, :approval}, state, _options),
    do: {:ok, "Codex approval and sandbox level", @codex_approval_items, state.approval_level}

  def ui({:overlay, :provider}, state, _options),
    do:
      {:state,
       if(state.codex.status in [:ready, :authenticating],
         do: codex_account_overlay(state),
         else: ensure_codex(state, true)
       )}

  def ui({:overlay, :model}, state, _options) do
    case state.codex do
      %{status: :ready, models: [_ | _] = models} ->
        {:ok, "Codex models · type to filter",
         Enum.map(models, &%{label: Host.model_label(&1), value: Host.model_id(&1)}),
         state.selected_model}

      _ ->
        {:state, ensure_codex(state, true)}
    end
  end

  def ui({:overlay, :effort}, %{codex: %{status: status}} = state, _options)
      when status != :ready,
      do: {:state, ensure_codex(state, true)}

  def ui({:select, :codex_login}, state, _options), do: start_codex_login(state)
  def ui({:select, :codex_refresh}, state, _options), do: refresh_codex(state)
  def ui({:select, :codex_reconnect}, state, _options), do: reconnect_codex(state)
  def ui({:select, :codex_logout}, state, _options), do: logout_codex(state)
  def ui({:select, {:codex_open_url, url}}, state, _options), do: open_codex_url(state, url)
  def ui({:select, {:codex_cancel_login, id}}, state, _options), do: cancel_codex_login(state, id)

  def ui({:select, value}, %{overlay: %{kind: :codex_error}} = state, _options)
      when is_binary(value),
      do: %{state | selected_model: value, overlay: nil}

  def ui(_event, _state, _options), do: :pass

  @impl true
  def cancel(%{client: client, thread_id: thread_id, turn_id: turn_id}, _reason, _options)
      when is_binary(thread_id) and is_binary(turn_id),
      do: CodexClient.interrupt_turn(client, thread_id, turn_id)

  def cancel(_run, _reason, _options), do: :ok
  defp handle_info(:ensure_codex_backend, state), do: {:noreply, ensure_codex(state, false)}

  defp handle_info({:codex_connected, result}, state) do
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

  defp handle_info({:codex_refreshed, result}, state) do
    case result do
      {:ok, %{models: models, rate_limits: limits}} ->
        selected =
          if selected?(state) do
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

  defp handle_info({:codex_limits_refreshed, {:ok, limits}}, state),
    do: {:noreply, put_in(state.codex.rate_limits, limits)}

  defp handle_info({:codex_limits_refreshed, _error}, state),
    do: {:noreply, state, render?: false}

  defp handle_info({:codex_login_started, result}, state) do
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

  defp handle_info({:codex_logout_finished, result}, state) do
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

  defp handle_info({:codex_history_loaded, task_id, result}, state) do
    codex = %{
      state.codex
      | history_loading: MapSet.delete(state.codex.history_loading, task_id)
    }

    state = %{state | codex: codex}

    case result do
      {:ok, entries} ->
        {:noreply, State.put_entries(state, task_id, entries)}

      {:error, reason} ->
        {:noreply,
         %{state | notice: "could not load Codex history · #{Host.human_error(reason)}"}}
    end
  end

  defp handle_info({:codex_turn_started, local_id, result}, state) do
    case {Map.get(state.runs, local_id), result} do
      {nil, _result} ->
        {:noreply, state, render?: false}

      {run, {:ok, %{thread_id: thread_id, turn_id: turn_id}}} ->
        run = %{
          run
          | thread_id: thread_id,
            turn_id: turn_id,
            status: :running,
            phase: "waiting for model"
        }

        state = put_in(state.runs[local_id], run)

        state =
          case Catalog.update_task(
                 run.task_id,
                 %{
                   "status" => "active",
                   "backend" => Atom.to_string(run.backend_id),
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

  defp handle_info(
         {:codex_notification, client, method, params},
         %{codex: %{client: client}} = state
       ) do
    {:noreply, ingest_codex_notification(state, method, params)}
  end

  defp handle_info(
         {:codex_request, client, id, method, params},
         %{codex: %{client: client}} = state
       ) do
    {:noreply, handle_codex_request(state, id, method, params)}
  end

  defp handle_info({:codex_browser_opened, {:error, reason}}, state),
    do:
      {:noreply,
       %{state | notice: "open the displayed URL manually · #{Host.human_error(reason)}"}}

  defp handle_info({:codex_browser_opened, _result}, state),
    do: {:noreply, state, render?: false}

  defp handle_info(_message, _state), do: :pass

  defp submit_codex(state, prompt) do
    cond do
      state.codex.status != :ready or is_nil(state.codex.client) ->
        ensure_codex(%{state | notice: "connect ChatGPT before sending"}, true)

      not CodexBackend.chatgpt_account?(state.codex.account) ->
        codex_account_overlay(%{state | notice: "sign in with ChatGPT before sending"})

      is_nil(state.selected_model) or state.selected_model == "" ->
        Host.open_overlay(%{state | notice: "choose a Codex model before sending"}, :model)

      true ->
        with {:ok, state, task} <- Host.ensure_task(state, prompt) do
          start_codex_task(state, task, prompt)
        else
          {:error, reason} -> %{state | notice: "cannot start: #{Host.human_error(reason)}"}
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
      effort:
        State.selected_effort(state) || (State.model_metadata(state) || %{})[:default_effort],
      approval: state.approval_level
    ]

    run = %{
      kind: :codex,
      backend_id: state.selected_backend,
      adapter: {:ok, __MODULE__, []},
      cancellation: :run,
      client: client,
      task_id: task["id"],
      thread_id: task["backend_thread_id"],
      turn_id: nil,
      status: :starting,
      phase: "waiting for Codex connection",
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
             %{"status" => "active", "backend" => Atom.to_string(run.backend_id)},
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

  defp maybe_load_codex_history(state) do
    task = State.selected_task(state)
    task_id = task && task["id"]
    thread_id = task && task["backend_thread_id"]
    entries = Map.get(state.entries, task_id, [])

    cond do
      not selected?(state) ->
        state

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
    message = reason |> Host.human_error() |> Host.redact_secrets() |> String.slice(0, 500)

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
    do:
      state
      |> codex_phase(run, "receiving response")
      |> State.append_assistant_delta(run.task_id, delta, :codex_assistant)

  defp apply_codex_run_event(state, run, method, %{"delta" => delta} = params)
       when method in ["item/reasoning/summaryTextDelta", "item/reasoning/textDelta"] do
    key = {:codex_reasoning, run.turn_id, params["itemId"]}
    entries = Map.get(state.entries, run.task_id, [])
    previous = Enum.find(entries, &(&1[:entry_key] == key)) || %{}
    parts = Map.get(previous, :reasoning_parts, %{summary: %{}, raw: %{}})
    type = if method == "item/reasoning/summaryTextDelta", do: :summary, else: :raw
    index = params["summaryIndex"] || params["contentIndex"] || 0
    parts = Map.update!(parts, type, &Map.update(&1, index, delta, fn text -> text <> delta end))
    chosen = if map_size(parts.summary) > 0, do: parts.summary, else: parts.raw
    text = chosen |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join("\n\n", &elem(&1, 1))

    state
    |> codex_phase(run, "thinking")
    |> State.upsert_entry(run.task_id, key, %{
      kind: :reasoning,
      text: text,
      reasoning_parts: parts
    })
  end

  defp apply_codex_run_event(state, run, "item/completed", %{
         "item" => %{"type" => "reasoning"} = item
       }) do
    text = CodexBackend.reasoning_text(item)

    if text == "",
      do: state,
      else:
        State.upsert_entry(state, run.task_id, {:codex_reasoning, run.turn_id, item["id"]}, %{
          kind: :reasoning,
          text: text
        })
  end

  defp apply_codex_run_event(state, run, "thread/tokenUsage/updated", %{"tokenUsage" => usage}) do
    state
    |> State.put_usage(run.task_id, Alto.Usage.from_codex(usage))
    |> put_in([Access.key!(:codex), Access.key!(:context_window)], usage["modelContextWindow"])
  end

  defp apply_codex_run_event(state, run, "item/started", %{"item" => item}) do
    state =
      cond do
        item["type"] == "reasoning" -> codex_phase(state, run, "thinking")
        codex_item_summary(item) != nil -> codex_phase(state, run, "running tool")
        true -> state
      end

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
          detail: Alto.Display.result(item)
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
    text = Map.get(params, "message") || Host.human_error(params)
    State.append_entry(state, run.task_id, %{kind: :error, text: text})
  end

  defp apply_codex_run_event(state, _run, _method, _params), do: state

  defp codex_phase(state, run, phase) do
    runs =
      Map.new(state.runs, fn {id, candidate} ->
        {id,
         if(candidate == run and Map.get(candidate, :phase) != "cancelling",
           do: Map.put(candidate, :phase, phase),
           else: candidate
         )}
      end)

    %{state | runs: runs}
  end

  defp codex_item_summary(%{"type" => "commandExecution", "command" => command}),
    do: "command · " <> Alto.Display.text(command)

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
    |> Host.drop_run(local_id)
    |> Map.put(:notice, if(completed?, do: "Codex run completed", else: "Codex run failed"))
    |> refresh_limits_after_turn()
    |> Host.finish_queued(run.task_id, completed?)
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
      text: "Codex could not start: #{Host.human_error(reason)}"
    })
    |> Host.drop_run(local_id)
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
              respond: fn decision ->
                CodexClient.respond(
                  state.codex.client,
                  id,
                  codex_approval_response(method, decision, params)
                )
              end,
              backend: :codex,
              local_id: local_id,
              client: state.codex.client,
              request_id: id,
              method: method,
              params: params,
              request: request
            }

            Host.show_pending_approval(
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

  defp backend_model(state) do
    Keyword.get(state.codex.options, :model) ||
      case Enum.find(state.codex.models, &Map.get(&1, :default?, false)) ||
             List.first(state.codex.models) do
        nil -> nil
        model -> model.id
      end
  end

  defp selected?(state) do
    case Alto.TUI.Backend.lookup(state.run_options, state.selected_backend) do
      {:ok, __MODULE__, _} -> true
      _ -> false
    end
  end
end
