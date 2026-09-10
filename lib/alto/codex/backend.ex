defmodule Alto.Codex.Backend do
  @moduledoc """
  First-class Codex execution backend for the Alto TUI.

  This is intentionally not an `Alto.Provider`: Codex App Server owns its agent
  loop, tools, context, and compaction. Alto owns project/task navigation, the
  TUI, approval presentation, and telemetry projection for these runs.
  """

  alias Alto.Codex.AppServer.Client

  @client_keys [
    :command,
    :args,
    :cwd,
    :env,
    :startup_timeout,
    :request_timeout,
    :max_message_bytes,
    :max_pending_requests,
    :max_ready_waiters,
    :max_subscribers
  ]

  @doc "Connect, subscribe the caller, and read the current account snapshot."
  def connect(opts \\ [], subscriber \\ self()) do
    client_opts = client_options(opts) |> Keyword.put(:instance, subscriber)

    with {:ok, client} <- Client.ensure_started(client_opts),
         :ok <- Client.subscribe(client, subscriber),
         {:ok, account} <- Client.account(client) do
      {:ok, %{client: client, account: account}}
    end
  end

  @doc "Fetch model and quota information after ChatGPT authentication."
  def refresh(client) do
    with {:ok, model_result} <- Client.models(client),
         {:ok, limits} <- Client.rate_limits(client) do
      models =
        model_result
        |> Map.get("data", [])
        |> Enum.map(&normalize_model/1)

      {:ok, %{models: models, rate_limits: limits}}
    end
  end

  @doc "Read a persisted Codex thread and project its visible items into Alto TUI entries."
  def history(client, thread_id) when is_binary(thread_id) do
    with {:ok, result} <- Client.read_thread(client, thread_id),
         turns when is_list(turns) <- get_in(result, ["thread", "turns"]) do
      {:ok, Enum.flat_map(turns, &history_turn/1)}
    else
      nil -> {:error, :codex_thread_history_missing}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_codex_thread_history, other}}
    end
  end

  @doc "Start or resume a Codex thread and begin one turn."
  def start_turn(client, thread_id, prompt, opts)
      when is_binary(prompt) and is_list(opts) do
    cwd = opts |> Keyword.fetch!(:cwd) |> Path.expand()
    model = Keyword.get(opts, :model)
    approval = Keyword.get(opts, :approval, :ask)

    with {:ok, thread_id} <- ensure_thread(client, thread_id, cwd, model, approval),
         {:ok, result} <-
           Client.start_turn(client, %{
             "threadId" => thread_id,
             "input" => [%{"type" => "text", "text" => prompt}],
             "cwd" => cwd,
             "model" => model,
             "approvalPolicy" => approval_policy(approval),
             "sandboxPolicy" => sandbox_policy(approval)
           }),
         turn_id when is_binary(turn_id) <- get_in(result, ["turn", "id"]) do
      {:ok, %{thread_id: thread_id, turn_id: turn_id}}
    else
      nil -> {:error, :codex_turn_id_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Open the managed ChatGPT OAuth URL with an injectable platform opener."
  def open_url(url, opts \\ []) when is_binary(url) do
    case Keyword.get(opts, :open_url) do
      fun when is_function(fun, 1) -> fun.(url)
      nil -> platform_open(url)
      other -> {:error, {:invalid_open_url, other}}
    end
  end

  @doc "Whether the current App Server account is subscription-backed ChatGPT auth."
  def chatgpt_account?(%{"account" => %{"type" => "chatgpt"}}), do: true
  def chatgpt_account?(_account), do: false

  def account_label(%{"account" => %{"type" => "chatgpt"} = account}) do
    plan = account |> Map.get("planType", "unknown") |> to_string() |> String.upcase()
    email = Map.get(account, "email")
    if is_binary(email) and email != "", do: "ChatGPT #{plan} · #{email}", else: "ChatGPT #{plan}"
  end

  def account_label(%{"account" => %{"type" => "apiKey"}}), do: "Codex API key (not subscription)"
  def account_label(_account), do: "ChatGPT · signed out"

  def primary_rate_limit(%{"rateLimits" => %{} = limits}), do: Map.get(limits, "primary")
  def primary_rate_limit(_limits), do: nil

  def approval_policy(:ask), do: "on-request"
  def approval_policy(:read_only), do: "never"
  def approval_policy(:full_access), do: "never"

  def sandbox_mode(:ask), do: "workspace-write"
  def sandbox_mode(:read_only), do: "read-only"
  def sandbox_mode(:full_access), do: "danger-full-access"

  def sandbox_policy(:ask),
    do: %{"type" => "workspaceWrite", "writableRoots" => [], "networkAccess" => false}

  def sandbox_policy(:read_only), do: %{"type" => "readOnly", "networkAccess" => false}
  def sandbox_policy(:full_access), do: %{"type" => "dangerFullAccess"}

  defp ensure_thread(client, thread_id, cwd, model, approval) when is_binary(thread_id) do
    params = thread_params(cwd, model, approval) |> Map.put("threadId", thread_id)

    case Client.resume_thread(client, params) do
      {:ok, result} -> extract_thread_id(result)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_thread(client, _thread_id, cwd, model, approval) do
    case Client.start_thread(client, thread_params(cwd, model, approval)) do
      {:ok, result} -> extract_thread_id(result)
      {:error, reason} -> {:error, reason}
    end
  end

  defp thread_params(cwd, model, approval) do
    %{
      "cwd" => cwd,
      "model" => model,
      "approvalPolicy" => approval_policy(approval),
      "sandbox" => sandbox_mode(approval),
      "approvalsReviewer" => "user",
      "serviceName" => "alto"
    }
  end

  defp extract_thread_id(result) do
    case get_in(result, ["thread", "id"]) do
      id when is_binary(id) -> {:ok, id}
      _other -> {:error, :codex_thread_id_missing}
    end
  end

  defp normalize_model(model) do
    %{
      id: Map.get(model, "model") || Map.fetch!(model, "id"),
      name: Map.get(model, "displayName") || Map.get(model, "id"),
      description: Map.get(model, "description"),
      default?: Map.get(model, "isDefault", false),
      default_effort: Map.get(model, "defaultReasoningEffort"),
      efforts: Map.get(model, "supportedReasoningEfforts", [])
    }
  end

  defp history_turn(%{"items" => items}) when is_list(items),
    do: Enum.flat_map(items, &history_item/1)

  defp history_turn(_turn), do: []

  defp history_item(%{"type" => "userMessage", "content" => content}) when is_list(content) do
    text =
      content
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) -> [text]
        _other -> []
      end)
      |> Enum.join("\n")

    if text == "", do: [], else: [%{kind: :user, text: text}]
  end

  defp history_item(%{"type" => "agentMessage", "text" => text}) when is_binary(text),
    do: [%{kind: :codex_assistant, text: text}]

  defp history_item(%{"type" => "commandExecution"} = item),
    do: [
      %{
        kind: :tool,
        text: "command · " <> inspect(item["command"]),
        detail: item["aggregatedOutput"]
      }
    ]

  defp history_item(%{"type" => "fileChange"} = item),
    do: [%{kind: :tool, text: "file changes", detail: inspect(item["changes"], pretty: true)}]

  defp history_item(%{"type" => "mcpToolCall"} = item),
    do: [
      %{
        kind: :tool,
        text: "MCP · #{item["server"]}/#{item["tool"]}",
        detail: inspect(item["result"], pretty: true)
      }
    ]

  defp history_item(%{"type" => "plan", "text" => text}) when is_binary(text),
    do: [%{kind: :system, text: "plan\n" <> text}]

  defp history_item(_item), do: []

  defp client_options(opts), do: Keyword.take(opts, @client_keys)

  defp platform_open(url) do
    candidates =
      case :os.type() do
        {:unix, :darwin} -> [{"open", [url]}]
        {:win32, _name} -> [{"cmd.exe", ["/c", "start", "", url]}]
        _other -> [{"xdg-open", [url]}, {"gio", ["open", url]}]
      end

    case Enum.find_value(candidates, fn {command, args} ->
           if executable = System.find_executable(command), do: {executable, args}
         end) do
      {executable, args} ->
        case System.cmd(executable, args, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:browser_open_failed, status, String.trim(output)}}
        end

      nil ->
        {:error, :browser_opener_not_found}
    end
  rescue
    error -> {:error, {:browser_open_failed, Exception.message(error)}}
  end
end
