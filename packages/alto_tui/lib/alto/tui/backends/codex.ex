defmodule Alto.TUI.Backends.Codex do
  @moduledoc "Codex account, protocol, approval and interactive lifecycle contributions."
  @behaviour Alto.TUI.Backend
  alias Alto.Codex.AppServer.Client, as: CodexClient
  alias Alto.Codex.Backend, as: CodexBackend
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
      history_loading: MapSet.new(),
      pending_messages: []
    }

    model =
      if selected?(state),
        do: Keyword.get(codex_options, :model),
        else: state.selected_model

    %{put_data(state, codex) | selected_model: model}
  end

  def ui(:provider_label, state, _options), do: CodexBackend.account_label(data(state).account)
  def ui(:context_window, state, _options), do: data(state).context_window

  def ui(:quota_label, state, _options) do
    case CodexBackend.primary_rate_limit(data(state).rate_limits) do
      %{"usedPercent" => used} when is_number(used) -> "  quota #{Float.round(used * 1.0, 1)}%"
      _ -> "  quota —"
    end
  end

  def ui(:models, state, _options), do: data(state).models

  def ui(:activity, %{backend_state: %{__MODULE__ => %{status: status}}}, _options)
      when status in [:connecting, :refreshing],
      do: "waiting for Codex connection"

  def ui(:sync_model, state, _options) do
    if Enum.any?(data(state).models, &((&1[:id] || &1["id"]) == state.selected_model)),
      do: state.selected_model,
      else: backend_model(state)
  end

  def ui({:message, message}, state, _options), do: handle_info(message, state)
  def ui({:submit, prompt}, state, _options), do: submit_codex(state, prompt)
  def ui(:model, state, _options), do: backend_model(state)
  def ui(:selected, state, _options), do: ensure_codex(state, true)

  def ui(:prepare, state, _options) do
    if data(state).status == :ready and is_pid(data(state).client),
      do: maybe_load_codex_history(state),
      else: ensure_codex(state, false)
  end

  def ui({:overlay, :approval}, state, _options),
    do: {:ok, "Codex approval and sandbox level", @codex_approval_items, state.approval_level}

  def ui({:overlay, :provider}, state, _options),
    do:
      {:state,
       if(data(state).status in [:ready, :authenticating],
         do: codex_account_overlay(state),
         else: ensure_codex(state, true)
       )}

  def ui({:overlay, :model}, state, _options) do
    case data(state) do
      %{status: :ready, models: [_ | _] = models} ->
        {:ok, "Codex models · type to filter",
         Enum.map(models, &%{label: Host.model_label(&1), value: Host.model_id(&1)}),
         state.selected_model}

      _ ->
        {:state, ensure_codex(state, true)}
    end
  end

  def ui(
        {:overlay, :effort},
        %{backend_state: %{__MODULE__ => %{status: status}}} = state,
        _options
      )
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
        codex = %{data(state) | client: client, status: :ready, account: account}
        next = put_data(state, codex)

        if CodexBackend.chatgpt_account?(account) do
          {:noreply, refresh_codex(next)}
        else
          {:noreply, codex_account_overlay(next)}
        end

      {:error, reason} ->
        next = put_in(state.backend_state[__MODULE__].status, {:error, reason})
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

        codex = %{data(state) | models: models, rate_limits: limits, status: :ready}
        next = %{put_data(state, codex) | selected_model: selected, notice: "ChatGPT ready"}

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
    do: {:noreply, put_in(state.backend_state[__MODULE__].rate_limits, limits)}

  defp handle_info({:codex_limits_refreshed, _error}, state),
    do: {:noreply, state, render?: false}

  defp handle_info({:codex_login_started, result}, state) do
    case result do
      {:ok, %{"authUrl" => url, "loginId" => _login_id} = login} ->
        open_codex_url(state, url)

        if CodexBackend.chatgpt_account?(data(state).account) do
          {:noreply, refresh_codex(state)}
        else
          codex = %{data(state) | login: login, status: :authenticating}

          next = %{
            put_data(state, codex)
            | overlay: codex_login_overlay(login),
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
          data(state)
          | account: nil,
            models: [],
            rate_limits: nil,
            login: nil,
            status: :ready
        }

        {:noreply, codex_account_overlay(%{put_data(state, codex) | selected_model: nil})}

      {:error, reason} ->
        {:noreply, codex_error_overlay(state, reason)}
    end
  end

  defp handle_info({:codex_history_loaded, task_id, result}, state) do
    codex = %{
      data(state)
      | history_loading: MapSet.delete(data(state).history_loading, task_id)
    }

    state = put_data(state, codex)

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

      {_run, {:ok, %{thread_id: thread_id, turn_id: turn_id}}} ->
        state =
          Host.update_run(state, local_id,
            thread_id: thread_id,
            turn_id: turn_id,
            status: :running,
            phase: "waiting for model"
          )

        run = state.runs[local_id]
        state = Host.sync_run_task(state, run)

        state = %{state | notice: "Codex working…"}
        {:noreply, replay_codex_messages(state, run)}

      {run, {:error, reason}} ->
        {:noreply, fail_codex_start(state, local_id, run, reason)}
    end
  end

  defp handle_info(
         {:codex_notification, client, method, params},
         %{backend_state: %{__MODULE__ => %{client: client}}} = state
       ) do
    {:noreply, ingest_codex_notification(state, method, params)}
  end

  defp handle_info(
         {:codex_request, client, id, method, params},
         %{backend_state: %{__MODULE__ => %{client: client}}} = state
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
      data(state).status != :ready or is_nil(data(state).client) ->
        ensure_codex(%{state | notice: "connect ChatGPT before sending"}, true)

      not CodexBackend.chatgpt_account?(data(state).account) ->
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
    client = data(state).client
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
      client: client,
      task_id: task["id"],
      thread_id: task["conversation_id"],
      turn_id: nil,
      status: :starting,
      phase: "waiting for Codex connection",
      approval_level: state.approval_level,
      started_at_ms: System.system_time(:millisecond)
    }

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      result = CodexBackend.start_turn(client, task["conversation_id"], prompt, opts)
      send(owner, {:codex_turn_started, local_id, result})
    end)

    Host.attach_run(state, local_id, run, prompt, "starting Codex…")
  end

  defp maybe_load_codex_history(state) do
    task = State.selected_task(state)
    task_id = task && task["id"]
    thread_id = task && task["conversation_id"]
    entries = Map.get(state.entries, task_id, [])

    cond do
      not selected?(state) ->
        state

      not is_binary(thread_id) ->
        state

      entries != [] ->
        state

      MapSet.member?(data(state).history_loading, task_id) ->
        state

      not is_pid(data(state).client) ->
        state

      true ->
        owner = self()
        client = data(state).client

        Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
          send(owner, {:codex_history_loaded, task_id, CodexBackend.history(client, thread_id)})
        end)

        put_in(
          state.backend_state[__MODULE__].history_loading,
          MapSet.put(data(state).history_loading, task_id)
        )
    end
  end

  defp ensure_codex(state, show_overlay?) do
    cond do
      data(state).status == :ready and is_pid(data(state).client) and
          Process.alive?(data(state).client) ->
        if show_overlay?, do: codex_account_overlay(state), else: state

      data(state).status == :authenticating and is_map(data(state).login) ->
        if show_overlay?,
          do: %{state | overlay: codex_login_overlay(data(state).login)},
          else: state

      data(state).status == :connecting ->
        if show_overlay?, do: %{state | overlay: codex_connecting_overlay()}, else: state

      data(state).status == :refreshing and is_pid(data(state).client) ->
        if show_overlay?,
          do: %{state | overlay: codex_connecting_overlay("refreshing models and quota…")},
          else: state

      true ->
        owner = self()
        opts = data(state).options

        Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
          send(owner, {:codex_connected, CodexBackend.connect(opts, owner)})
        end)

        codex = %{data(state) | status: :connecting}
        next = %{put_data(state, codex) | notice: "connecting to Codex App Server…"}
        if show_overlay?, do: %{next | overlay: codex_connecting_overlay()}, else: next
    end
  end

  defp refresh_codex(%{backend_state: %{__MODULE__ => %{client: client}}} = state)
       when is_pid(client) do
    owner = self()

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      send(owner, {:codex_refreshed, CodexBackend.refresh(client)})
    end)

    put_in(state.backend_state[__MODULE__].status, :refreshing)
  end

  defp refresh_codex(state), do: ensure_codex(state, true)

  defp reconnect_codex(state) do
    codex = %{
      data(state)
      | client: nil,
        status: :idle,
        account: nil,
        models: [],
        rate_limits: nil
    }

    ensure_codex(put_data(state, codex), true)
  end

  defp start_codex_login(%{backend_state: %{__MODULE__ => %{client: client}}} = state)
       when is_pid(client) do
    owner = self()

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      send(owner, {:codex_login_started, CodexClient.login_chatgpt(client)})
    end)

    codex = %{data(state) | status: :authenticating, login: nil}
    %{put_data(state, codex) | overlay: codex_connecting_overlay("starting ChatGPT sign-in…")}
  end

  defp start_codex_login(state), do: ensure_codex(state, true)

  defp logout_codex(%{backend_state: %{__MODULE__ => %{client: client}}} = state)
       when is_pid(client) do
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

  defp cancel_codex_login(%{backend_state: %{__MODULE__ => %{client: client}}} = state, login_id)
       when is_pid(client) do
    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      CodexClient.request(client, "account/login/cancel", %{"loginId" => login_id})
    end)

    codex = %{data(state) | status: :ready, login: nil}
    codex_account_overlay(%{put_data(state, codex) | notice: "ChatGPT sign-in cancelled"})
  end

  defp cancel_codex_login(state, _login_id), do: state

  defp open_codex_url(state, url) do
    owner = self()
    opts = data(state).options

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
    account = data(state).account

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
              %{label: "Sign in with ChatGPT subscription…", value: :codex_login}
            ] ++ alternative_backends(state)
          }

        true ->
          {
            "Sign in through the official managed ChatGPT OAuth flow. Alto never receives the token.",
            [
              %{label: "Sign in with ChatGPT subscription…", value: :codex_login}
            ] ++ alternative_backends(state)
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

    items =
      [
        %{label: "Retry Codex connection", value: :codex_reconnect}
      ] ++ alternative_backends(state)

    codex = %{data(state) | status: {:error, reason}}

    %{
      put_data(state, codex)
      | overlay: list_overlay(:codex_error, "Codex unavailable", message, items),
        notice: "Codex needs attention"
    }
  end

  defp alternative_backends(state) do
    state.run_options
    |> Alto.TUI.Backend.items()
    |> Enum.reject(&(&1.value == state.selected_backend))
    |> Enum.map(&%{label: "Use " <> &1.label, value: {:select_backend, &1.value}})
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
    do: put_in(state.backend_state[__MODULE__].rate_limits, params)

  defp ingest_codex_notification(state, method, params) do
    case find_codex_run(state, params) do
      nil -> maybe_buffer_codex_event(state, method, params)
      {_local_id, run} -> apply_codex_run_event(state, run, method, params)
    end
  end

  defp reconnect_codex_account(%{backend_state: %{__MODULE__ => %{client: client}}} = state)
       when is_pid(client) do
    owner = self()

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      result =
        with {:ok, account} <- CodexClient.account(client) do
          {:ok, %{client: client, account: account}}
        end

      send(owner, {:codex_connected, result})
    end)

    put_in(state.backend_state[__MODULE__].status, :refreshing)
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
      buffer_codex_message(state, {:notification, method, params})
    else
      state
    end
  end

  defp replay_codex_messages(state, run) do
    {matching, rest} =
      Enum.split_with(data(state).pending_messages, fn message ->
        params = elem(message, tuple_size(message) - 1)

        (params["threadId"] || params["conversationId"]) == run.thread_id and
          (is_nil(params["turnId"]) or params["turnId"] == run.turn_id)
      end)

    state = put_in(state.backend_state[__MODULE__].pending_messages, rest)

    Enum.reduce(matching, state, fn
      {:notification, method, params}, acc -> apply_codex_run_event(acc, run, method, params)
      {:request, id, method, params}, acc -> handle_codex_request(acc, id, method, params)
    end)
  end

  defp buffer_codex_message(state, message) do
    messages = data(state).pending_messages ++ [message]
    {dropped, pending} = Enum.split(messages, max(length(messages) - 100, 0))

    Enum.each(dropped, fn
      {:request, id, _method, _params} ->
        CodexClient.reject(data(state).client, id, -32001, "approval expired before turn start")

      _notification ->
        :ok
    end)

    put_in(state.backend_state[__MODULE__].pending_messages, pending)
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
    |> put_in(
      [Access.key!(:backend_state), Access.key!(__MODULE__), Access.key!(:context_window)],
      usage["modelContextWindow"]
    )
  end

  defp apply_codex_run_event(state, run, "item/started", %{"item" => item}) do
    state =
      cond do
        item["type"] == "reasoning" -> codex_phase(state, run, "thinking")
        CodexBackend.item_summary(item) != nil -> codex_phase(state, run, "running tool")
        true -> state
      end

    case CodexBackend.item_summary(item) do
      nil -> state
      text -> State.append_entry(state, run.task_id, %{kind: :tool, text: text <> " …"})
    end
  end

  defp apply_codex_run_event(state, run, "item/completed", %{"item" => item}) do
    case CodexBackend.item_summary(item) do
      nil ->
        state

      text ->
        entry = CodexBackend.item_entry(item)
        State.append_entry(state, run.task_id, %{entry | text: text <> " ✓"})
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
    if Map.get(run, :phase) == "cancelling",
      do: state,
      else: Host.update_run(state, run, phase: phase)
  end

  defp finish_codex_run(state, run, status, error) do
    completed? = status == "completed"
    catalog_status = if completed?, do: "completed", else: "failed"

    local_id =
      Enum.find_value(state.runs, fn {id, candidate} -> if candidate == run, do: id end)

    state
    |> Host.finish_run(local_id, catalog_status,
      entry:
        if(completed?,
          do: nil,
          else: %{kind: :error, text: error || "Codex turn #{status || "failed"}"}
        ),
      notice: if(completed?, do: "Codex run completed", else: "Codex run failed"),
      continue?: completed?
    )
    |> refresh_limits_after_turn()
  end

  defp refresh_limits_after_turn(%{backend_state: %{__MODULE__ => %{client: client}}} = state)
       when is_pid(client) do
    owner = self()

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      send(owner, {:codex_limits_refreshed, CodexClient.rate_limits(client)})
    end)

    state
  end

  defp refresh_limits_after_turn(state), do: state

  defp fail_codex_start(state, local_id, _run, reason) do
    Host.finish_run(state, local_id, "failed",
      entry: %{kind: :error, text: "Codex could not start: #{Host.human_error(reason)}"},
      notice: "Codex run failed to start",
      continue?: false
    )
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
          buffer_codex_message(state, {:request, id, method, params})
        else
          CodexClient.reject(data(state).client, id, -32001, "no matching Alto task")
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
                  data(state).client,
                  id,
                  codex_approval_response(method, decision, params)
                )
              end,
              local_id: local_id,
              request: request
            }

            Host.show_pending_approval(
              state,
              pending,
              "Codex approval required · F8 approve / F9 deny"
            )

          :read_only ->
            CodexClient.respond(
              data(state).client,
              id,
              codex_approval_response(method, {:deny, :read_only}, params)
            )

            state

          :full_access ->
            CodexClient.respond(
              data(state).client,
              id,
              codex_approval_response(method, :approve, params)
            )

            state
        end
    end
  end

  defp handle_codex_request(state, id, _method, _params) do
    CodexClient.reject(data(state).client, id)
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
    Keyword.get(data(state).options, :model) ||
      case Enum.find(data(state).models, &Map.get(&1, :default?, false)) ||
             List.first(data(state).models) do
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

  defp data(state), do: Map.fetch!(state.backend_state, __MODULE__)
  defp put_data(state, value), do: put_in(state.backend_state[__MODULE__], value)
end
