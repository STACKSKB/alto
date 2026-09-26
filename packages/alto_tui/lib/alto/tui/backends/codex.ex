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

  @approval_methods %{
    "item/commandExecution/requestApproval" => {"Codex command", :decision},
    "item/fileChange/requestApproval" => {"Codex file changes", :decision},
    "item/permissions/requestApproval" => {"Codex permissions", :permissions},
    "execCommandApproval" => {"Codex command", :exec_decision},
    "applyPatchApproval" => {"Codex file changes", :exec_decision}
  }

  @impl true
  def ui(:init, state, options) do
    codex_options = Keyword.delete(options, :label)

    codex = %{
      options: codex_options,
      client: nil,
      status: :idle,
      account: nil,
      models: [],
      rate_limits: nil,
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

  def ui(:quota_label, state, _options) do
    case CodexBackend.primary_rate_limit(data(state).rate_limits) do
      %{"usedPercent" => used} when is_number(used) -> "  quota #{Float.round(used * 1.0, 1)}%"
      _ -> "  quota —"
    end
  end

  def ui(:models, state, _options), do: data(state).models

  def ui(:activity, %{backend_state: %{__MODULE__ => %{status: status}}}, _options)
      when status in [:connecting, :refreshing] or
             (is_tuple(status) and elem(status, 0) == :authenticating),
      do: "waiting for Codex connection"

  def ui(:sync_model, state, _options) do
    if Enum.any?(data(state).models, &((&1[:id] || &1["id"]) == state.selected_model)),
      do: state.selected_model,
      else: backend_model(state)
  end

  def ui({:message, message}, state, _options), do: handle_info(message, state)
  def ui({:submit, prompt}, state, _options), do: submit_codex(state, prompt)
  def ui(:selected, state, _options), do: ensure_codex(state, true)

  def ui(:prepare, state, _options) do
    if ready?(state),
      do: maybe_load_codex_history(state),
      else: ensure_codex(state, false)
  end

  def ui({:overlay, :approval}, state, _options),
    do: {:ok, "Codex approval and sandbox level", @codex_approval_items, state.approval_level}

  def ui({:overlay, :provider}, state, _options),
    do: {:state, ensure_codex(state, true)}

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

  defp handle_info({tag, {:error, reason}}, state)
       when tag in [
              :codex_connected,
              :codex_refreshed,
              :codex_login_started,
              :codex_logout_finished
            ],
       do: {:noreply, codex_error_overlay(state, reason)}

  defp handle_info({:codex_connected, {:ok, %{client: client, account: account}}}, state) do
    codex = %{data(state) | client: client, status: :ready, account: account}
    next = put_data(state, codex)

    if CodexBackend.chatgpt_account?(account) do
      {:noreply, refresh_codex(next)}
    else
      {:noreply, codex_account_overlay(next)}
    end
  end

  defp handle_info({:codex_refreshed, {:ok, %{models: models, rate_limits: limits}}}, state) do
    selected =
      if selected?(state) and not Enum.any?(models, &(&1.id == state.selected_model)) do
        default_model(models)
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
  end

  defp handle_info({:codex_limits_refreshed, {:ok, limits}}, state),
    do: {:noreply, put_in(state.backend_state[__MODULE__].rate_limits, limits)}

  defp handle_info({:codex_limits_refreshed, _error}, state),
    do: {:noreply, state, render?: false}

  defp handle_info(
         {:codex_login_started, {:ok, %{"authUrl" => url, "loginId" => _login_id} = login}},
         state
       ) do
    open_codex_url(state, url)

    if CodexBackend.chatgpt_account?(data(state).account) do
      {:noreply, refresh_codex(state)}
    else
      codex = %{data(state) | status: {:authenticating, login}}

      next = %{
        put_data(state, codex)
        | overlay: codex_login_overlay(login),
          notice: "waiting for ChatGPT sign-in"
      }

      {:noreply, next}
    end
  end

  defp handle_info({:codex_logout_finished, {:ok, _result}}, state) do
    codex = %{
      data(state)
      | account: nil,
        models: [],
        rate_limits: nil,
        status: :ready
    }

    {:noreply, codex_account_overlay(%{put_data(state, codex) | selected_model: nil})}
  end

  defp handle_info({:codex_history_loaded, task_id, result}, state) do
    state =
      update_in(state.backend_state[__MODULE__].history_loading, &MapSet.delete(&1, task_id))

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
            phase: "waiting for model"
          )

        run = state.runs[local_id]
        state = Host.sync_run_task(state, run)

        state = %{state | notice: "Codex working…"}
        {:noreply, replay_codex_messages(state, run)}

      {_run, {:error, reason}} ->
        {:noreply, fail_codex_start(state, local_id, reason)}
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
      not ready?(state) ->
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
      phase: "waiting for Codex connection",
      approval_level: state.approval_level,
      started_at_ms: System.system_time(:millisecond)
    }

    async_send({:codex_turn_started, local_id}, fn ->
      CodexBackend.start_turn(client, task["conversation_id"], prompt, opts)
    end)

    Host.attach_run(state, local_id, run, prompt, "starting Codex…")
  end

  defp maybe_load_codex_history(state) do
    task = State.selected_task(state)
    task_id = task && task["id"]
    thread_id = task && task["conversation_id"]
    entries = Map.get(state.entries, task_id, [])

    if selected?(state) and is_binary(thread_id) and entries == [] and
         not MapSet.member?(data(state).history_loading, task_id) and is_pid(data(state).client) do
      client = data(state).client

      async_send({:codex_history_loaded, task_id}, fn ->
        CodexBackend.history(client, thread_id)
      end)

      update_in(state.backend_state[__MODULE__].history_loading, &MapSet.put(&1, task_id))
    else
      state
    end
  end

  defp ensure_codex(state, show_overlay?) do
    cond do
      ready?(state) ->
        if show_overlay?, do: codex_account_overlay(state), else: state

      match?({:authenticating, login} when is_map(login), data(state).status) ->
        {:authenticating, login} = data(state).status

        if show_overlay?,
          do: %{state | overlay: codex_login_overlay(login)},
          else: state

      data(state).status == {:authenticating, :pending} ->
        if show_overlay?,
          do: %{state | overlay: codex_connecting_overlay("starting ChatGPT sign-in…")},
          else: state

      data(state).status == :connecting ->
        if show_overlay?, do: %{state | overlay: codex_connecting_overlay()}, else: state

      data(state).status == :refreshing and is_pid(data(state).client) ->
        if show_overlay?,
          do: %{state | overlay: codex_connecting_overlay("refreshing models and quota…")},
          else: state

      true ->
        opts = data(state).options
        owner = self()
        async_send({:codex_connected}, fn -> CodexBackend.connect(opts, owner) end)

        codex = %{data(state) | status: :connecting}
        next = %{put_data(state, codex) | notice: "connecting to Codex App Server…"}
        if show_overlay?, do: %{next | overlay: codex_connecting_overlay()}, else: next
    end
  end

  defp refresh_codex(%{backend_state: %{__MODULE__ => %{client: client}}} = state)
       when is_pid(client) do
    async_send({:codex_refreshed}, fn -> CodexBackend.refresh(client) end)

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
    async_send({:codex_login_started}, fn -> CodexClient.login_chatgpt(client) end)

    codex = %{data(state) | status: {:authenticating, :pending}}
    %{put_data(state, codex) | overlay: codex_connecting_overlay("starting ChatGPT sign-in…")}
  end

  defp start_codex_login(state), do: ensure_codex(state, true)

  defp logout_codex(%{backend_state: %{__MODULE__ => %{client: client}}} = state)
       when is_pid(client) do
    async_send({:codex_logout_finished}, fn -> CodexClient.logout(client) end)

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

    codex = %{data(state) | status: :ready}
    codex_account_overlay(%{put_data(state, codex) | notice: "ChatGPT sign-in cancelled"})
  end

  defp cancel_codex_login(state, _login_id), do: state

  defp open_codex_url(state, url) do
    opts = data(state).options
    async_send({:codex_browser_opened}, fn -> CodexBackend.open_url(url, opts) end)

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
      if CodexBackend.chatgpt_account?(account) do
        {
          CodexBackend.account_label(account) <>
            "\nOAuth credentials and refresh remain owned by Codex App Server and are shared with local Codex clients.",
          [
            %{label: "Refresh models and quota", value: :codex_refresh},
            %{label: "Sign out of ChatGPT (also signs out Codex CLI)", value: :codex_logout}
          ]
        }
      else
        message =
          if get_in(account || %{}, ["account", "type"]) == "apiKey",
            do: "Codex is using an API key, not ChatGPT subscription access.",
            else:
              "Sign in through the official managed ChatGPT OAuth flow. Alto never receives the token."

        {message,
         [%{label: "Sign in with ChatGPT subscription…", value: :codex_login}] ++
           alternative_backends(state)}
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
    message = reason |> Host.human_error() |> String.slice(0, 500)

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

  defp list_overlay(kind, title, message, items),
    do: Alto.TUI.Menu.new(kind, title, items) |> Map.put(:message, message)

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
    async_send({:codex_connected}, fn ->
      with {:ok, account} <- CodexClient.account(client) do
        {:ok, %{client: client, account: account}}
      end
    end)

    put_in(state.backend_state[__MODULE__].status, :refreshing)
  end

  defp reconnect_codex_account(state), do: state

  defp find_codex_run(state, params),
    do: Enum.find(state.runs, fn {_id, run} -> matches_codex_run?(run, params) end)

  defp matches_codex_run?(run, params) do
    thread_id = Map.get(params, "threadId") || Map.get(params, "conversationId")
    turn_id = Map.get(params, "turnId") || get_in(params, ["turn", "id"])

    run.kind == :codex and run.thread_id == thread_id and
      (is_nil(turn_id) or is_nil(run.turn_id) or run.turn_id == turn_id)
  end

  defp maybe_buffer_codex_event(state, method, params) do
    if Enum.any?(state.runs, fn {_id, run} -> run.kind == :codex and is_nil(run.turn_id) end) do
      buffer_codex_message(state, {:notification, method, params})
    else
      state
    end
  end

  defp replay_codex_messages(state, run) do
    {matching, rest} =
      Enum.split_with(data(state).pending_messages, fn message ->
        matches_codex_run?(run, elem(message, tuple_size(message) - 1))
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

  defp apply_codex_run_event(state, run, "thread/tokenUsage/updated", %{"tokenUsage" => usage}) do
    State.put_usage(state, run.task_id, Alto.Usage.from_codex(usage))
  end

  defp apply_codex_run_event(state, run, "item/started", %{"item" => item}) do
    summary = CodexBackend.item_summary(item)

    state =
      cond do
        item["type"] == "reasoning" -> codex_phase(state, run, "thinking")
        summary != nil -> codex_phase(state, run, "running tool")
        true -> state
      end

    case summary do
      nil -> state
      text -> State.append_entry(state, run.task_id, %{kind: :tool, text: text <> " …"})
    end
  end

  defp apply_codex_run_event(state, run, "item/completed", %{"item" => item}) do
    case CodexBackend.item_entry(item) do
      %{kind: :reasoning} = entry ->
        State.upsert_entry(state, run.task_id, {:codex_reasoning, run.turn_id, item["id"]}, entry)

      %{kind: :tool, text: text} = entry ->
        State.append_entry(state, run.task_id, %{entry | text: text <> " ✓"})

      _other ->
        state
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
    completed? = status == "completed"
    catalog_status = if completed?, do: "completed", else: "failed"

    state
    |> Host.finish_run(run.local_id, catalog_status,
      entry:
        if(completed?,
          do: nil,
          else: %{kind: :error, text: error || "Codex turn #{status || "failed"}"}
        ),
      notice: if(completed?, do: "Codex run completed", else: "Codex run failed")
    )
    |> refresh_limits_after_turn()
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

  defp refresh_limits_after_turn(%{backend_state: %{__MODULE__ => %{client: client}}} = state)
       when is_pid(client) do
    async_send({:codex_limits_refreshed}, fn -> CodexClient.rate_limits(client) end)

    state
  end

  defp refresh_limits_after_turn(state), do: state

  defp fail_codex_start(state, local_id, reason) do
    Host.finish_run(state, local_id, "failed",
      entry: %{kind: :error, text: "Codex could not start: #{Host.human_error(reason)}"},
      notice: "Codex run failed to start"
    )
  end

  defp handle_codex_request(state, id, method, params)
       when is_map_key(@approval_methods, method) do
    case find_codex_run(state, params) do
      nil ->
        if Enum.any?(state.runs, fn {_run_id, run} ->
             run.kind == :codex and is_nil(run.turn_id)
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
              tool: elem(Map.fetch!(@approval_methods, method), 0),
              arguments:
                Map.take(params, ~w(command cwd reason fileChanges grantRoot permissions)),
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

          level when level in [:read_only, :full_access] ->
            decision = if level == :full_access, do: :approve, else: {:deny, :read_only}

            CodexClient.respond(
              data(state).client,
              id,
              codex_approval_response(method, decision, params)
            )

            state
        end
    end
  end

  defp handle_codex_request(state, id, _method, _params) do
    CodexClient.reject(data(state).client, id)
    state
  end

  defp codex_approval_response(method, decision, params) do
    case elem(Map.fetch!(@approval_methods, method), 1) do
      :permissions ->
        permissions = if decision == :approve, do: Map.get(params, "permissions", %{}), else: %{}
        %{"permissions" => permissions, "scope" => "turn"}

      kind ->
        approved = if kind == :exec_decision, do: "approved", else: "accept"
        denied = if kind == :exec_decision, do: "abort", else: "decline"
        %{"decision" => if(decision == :approve, do: approved, else: denied)}
    end
  end

  defp backend_model(state),
    do: Keyword.get(data(state).options, :model) || default_model(data(state).models)

  defp default_model(models) do
    case Enum.find(models, &Map.get(&1, :default?, false)) || List.first(models) do
      nil -> nil
      model -> model.id
    end
  end

  defp ready?(state) do
    data(state).status == :ready and is_pid(data(state).client) and
      Process.alive?(data(state).client)
  end

  defp async_send(prefix, fun) do
    owner = self()

    Task.Supervisor.start_child(Alto.TaskSupervisor, fn ->
      send(owner, Tuple.insert_at(prefix, tuple_size(prefix), fun.()))
    end)
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
