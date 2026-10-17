defmodule Alto.Contrib.Resident.Console do
  @moduledoc """
  Transport-independent state for a reconnecting terminal client.

  Call `perform/3` outside the rendering process, passing that process as owner.
  Reads are repeatable; failed submissions are never retried automatically.
  History uses Alto's persisted cursors, independently of live notification IDs.
  """

  alias Alto.Contrib.Socket.{Client, SSH}
  alias Alto.Contrib.Resident.Config

  @active_statuses ~w(running waiting queued starting awaiting_admission waiting_approval)

  defstruct opts: [],
            workspace_id: nil,
            workspace_root: nil,
            workspace_base: nil,
            projects: [],
            client: nil,
            tunnel: nil,
            tasks: [],
            selected_id: nil,
            entries: [],
            detail: "",
            connection: "offline",
            notice: "",
            approvals: %{},
            history: [],
            history_session_id: nil,
            tasks_trimmed: false,
            cursor: 0,
            transcript: [],
            history_gap: false,
            history_trimmed: false,
            transcript_trimmed: false,
            history_more: false,
            effort_catalog: nil,
            selected_effort: nil,
            live_entries: %{},
            live: %{}

  def new(opts \\ []), do: %__MODULE__{opts: opts}

  def perform(model, action, owner) do
    do_perform(model, action, owner) |> present()
  catch
    {:console, reason} -> failed(model, action, reason)
    :exit, reason -> failed(model, action, reason)
  end

  @doc "Complete paths on the service host; safe to call from a background task."
  def complete_folders(%{client: nil}, _path), do: {:error, :disconnected}

  def complete_folders(model, path) do
    reply = command(model.client, "projects.complete", %{path: path})

    folders = reply["folders"] || []
    completion = Map.get(reply, "completion", nil)
    {:ok, %{folders: folders, completion: completion}}
  catch
    {:console, reason} -> {:error, reason}
    :exit, reason -> {:error, reason}
  end

  def close(model) do
    if model.client, do: Client.close(model.client)
    if model.tunnel, do: SSH.close(model.tunnel)
    :ok
  end

  defp do_perform(model, :connect, owner) do
    close(model)
    {path, tunnel} = transport(model.opts, owner)

    case Client.connect(path, owner: owner) do
      {:ok, client} ->
        connected = %{
          model
          | client: client,
            tunnel: tunnel,
            connection: "connected",
            approvals: %{},
            live: %{},
            live_entries: %{},
            notice: "Connected"
        }

        try do
          # Approval/result notifications are delivered regardless of domain.
          request(client, %{type: "attach", domains: ["live"]})
          reply = command(client, "projects.list", %{})
          default = reply["default"]

          projects = reply["projects"]
          open = Enum.reject(projects, &(&1["closed"] == true))

          workspace =
            Enum.find(
              open,
              &(&1["id"] == connected.workspace_id or &1["root"] == connected.workspace_root)
            ) ||
              Enum.find(open, &(&1["id"] == default["id"])) || List.first(open)

          connected = %{
            connected
            | projects: projects,
              workspace_base: default["root"],
              workspace_id: workspace && workspace["id"],
              workspace_root: workspace && workspace["root"]
          }

          refresh(reset_history(connected))
        catch
          kind, reason ->
            close(connected)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, reason} ->
        if tunnel, do: SSH.close(tunnel)
        throw({:console, reason})
    end
  end

  defp do_perform(model, :new, _owner) do
    task = selected(model)

    new_task(
      model,
      if(task, do: Map.get(task, :workspace_id), else: model.workspace_id),
      if(task, do: Map.get(task, :cwd), else: model.workspace_root),
      "New task"
    )
  end

  defp do_perform(model, {:select, id}, _owner) do
    if Enum.any?(model.tasks, &(&1.id == id)),
      do:
        reset_history(%{model | selected_id: id, notice: ""})
        |> load_task_detail()
        |> load_history(),
      else: %{model | notice: "Task is no longer available"}
  end

  defp do_perform(model, {:select_workspace, id}, _owner) do
    case Enum.find(model.projects, &(&1["id"] == id and &1["closed"] != true)) do
      nil ->
        %{model | notice: "Workspace is no longer available"}

      project ->
        new_task(model, id, project["root"], "New task in " <> project["name"])
    end
  end

  defp do_perform(%{client: nil} = model, _action, _owner),
    do: %{model | notice: "Reconnect before sending commands"}

  defp do_perform(model, {:close_workspace, nil}, _owner),
    do: %{model | notice: "No workspace to close"}

  defp do_perform(model, {:close_workspace, id}, _owner) do
    reply = command(model.client, "projects.close", %{id: id})
    project = reply["project"]
    task = selected(model)

    closing_current? =
      if task,
        do: Map.get(task, :workspace_id) == id or Map.get(task, :cwd) == project["root"],
        else: model.workspace_id == id or model.workspace_root == project["root"]

    model = %{model | projects: reply["projects"]}

    notice = "Workspace closed · reopen its folder to return"

    if closing_current? do
      next = Enum.find(model.projects, &(&1["closed"] != true))

      new_task(model, next && next["id"], next && next["root"], notice)
    else
      %{model | notice: notice}
    end
  end

  defp do_perform(model, {action, path}, _owner) when action in [:workspace, :create_workspace] do
    operation = if action == :create_workspace, do: "projects.create", else: "projects.open"
    reply = command(model.client, operation, %{path: path})

    project = reply["project"]

    model = %{
      model
      | projects: [project | Enum.reject(model.projects, &(&1["id"] == project["id"]))]
    }

    new_task(model, project["id"], project["root"], "Workspace opened: " <> project["root"])
  end

  defp do_perform(model, :efforts, _owner) do
    task = selected(model)
    profile = (task && task.config) || Keyword.get(model.opts, :profile, "coding")
    info = command(model.client, "tasks.efforts", %{"profile" => profile})

    same_model? =
      model.effort_catalog && model.effort_catalog["profile"] == profile &&
        model.effort_catalog["model"] == info["model"]

    selected =
      if same_model? && model.selected_effort in info["efforts"],
        do: model.selected_effort,
        else: nil

    %{
      model
      | effort_catalog: Map.put(info, "profile", profile),
        selected_effort: selected,
        notice: ""
    }
  end

  defp do_perform(model, {:effort, value}, _owner) do
    if value == nil or (model.effort_catalog && value in model.effort_catalog["efforts"]) do
      %{
        model
        | selected_effort: value,
          notice: "Effort: #{value || "provider default"} · next turn"
      }
    else
      %{model | notice: "Effort is not supported by this model"}
    end
  end

  defp do_perform(model, {:command, name, payload}, _owner) do
    command(model.client, name, payload)
    refresh_after_success(model, "Decision recorded")
  end

  defp do_perform(model, :recover, _owner) do
    case selected(model) do
      %{durable: true, id: id, revision: revision} ->
        detail = command(model.client, "tasks.get", %{"id" => id})["task"]
        parent = detail["parent_continuation"]

        if is_map(parent) and is_map(parent["identity"]) do
          payload =
            Map.merge(parent["identity"], %{
              "id" => id,
              "revision" => revision,
              "continuation_revision" => parent["revision"]
            })

          command(model.client, "tasks.recover", payload)
          refresh_after_success(model, "Recovery requested")
        else
          %{model | notice: "No recoverable parent continuation"}
        end

      _ ->
        %{model | notice: "Select a durable task"}
    end
  end

  defp do_perform(model, :poll, _owner), do: refresh(model)

  defp do_perform(model, {:submit, text}, _owner) do
    task = selected(model)

    cond do
      task == nil and model.workspace_root == nil ->
        %{model | notice: "Open a workspace first · ^G W"}

      task && is_nil(Map.get(task, :cwd)) ->
        %{model | notice: "Workspace is unknown; open a workspace before continuing this task"}

      String.trim(text) == "" ->
        %{model | notice: "Enter a message first"}

      byte_size(text) > 32_000 ->
        %{model | notice: "Message exceeds 32000 bytes"}

      task && task.status in @active_statuses ->
        %{model | notice: "This task is still running; start a new task for independent work"}

      task && task.status == "requires_operator" ->
        %{model | notice: "Resolve the uncertain outcome before continuing this task"}

      true ->
        profile = (task && task.config) || Keyword.get(model.opts, :profile, "coding")
        workspace_id = if task, do: Map.get(task, :workspace_id), else: model.workspace_id
        payload = %{"profile" => profile, "task" => text, "workspace_id" => workspace_id}

        payload =
          if model.selected_effort && model.effort_catalog &&
               model.effort_catalog["profile"] == profile,
             do: Map.put(payload, "reasoning_effort", model.selected_effort),
             else: payload

        payload =
          if task && task.session_id,
            do: Map.put(payload, "resume", task.session_id),
            else: payload

        reply = command(model.client, "tasks.submit", payload)
        model = reset_history(%{model | selected_id: reply["task_id"]})
        refresh_after_success(model, "Sent")
    end
  end

  defp do_perform(model, :cancel, _owner) do
    case selected(model) do
      %{durable: true, id: id, status: status}
      when status in @active_statuses ->
        command(model.client, "tasks.cancel", %{"id" => id})
        refresh_after_success(model, "Cancellation requested")

      %{run_id: run, status: status} when not is_nil(run) and status in ["running", "waiting"] ->
        request(model.client, %{type: "cancel", run_id: run, reason: "user"})
        %{model | notice: "Cancellation requested"}

      _ ->
        %{model | notice: "No running task selected"}
    end
  end

  defp do_perform(model, {:reconcile, resolution, note}, _owner) do
    case selected(model) do
      %{durable: true, id: id, revision: revision, status: "requires_operator"} ->
        command(model.client, "tasks.reconcile", %{
          "id" => id,
          "revision" => revision,
          "resolution" => resolution,
          "note" => note
        })

        refresh_after_success(model, "Decision recorded")

      _ ->
        %{model | notice: "Select a task requiring operator review"}
    end
  end

  defp do_perform(model, decision, _owner) when decision in [:approve, :deny] do
    case selected(model) do
      %{durable: true, upgrade_required: reason} when is_binary(reason) ->
        %{model | notice: "Resolve this approval with the previous version before upgrading"}

      %{durable: true, status: "waiting_approval", id: id, revision: revision} ->
        command(model.client, "tasks.decide", %{
          "id" => id,
          "revision" => revision,
          "decision" => Atom.to_string(decision)
        })

        refresh_after_success(model, "Decision sent")

      _ ->
        live_decision(model, decision)
    end
  end

  defp live_decision(model, decision) do
    case selected_approvals(model) do
      [] ->
        %{model | notice: "No pending decision for this task"}

      [approval | _] ->
        answer = if decision == :approve, do: "approve", else: %{"deny" => "user"}

        request(model.client, %{
          type: "approval_response",
          request_id: approval["id"],
          decision: answer
        })

        %{model | approvals: Map.delete(model.approvals, approval["id"]), notice: "Decision sent"}
    end
  end

  defp transport(opts, owner) do
    case Keyword.get(opts, :ssh) do
      nil ->
        {Keyword.get(opts, :socket, Path.join(Config.default_state_dir(), "service.sock")), nil}

      host ->
        ssh_opts = opts |> Keyword.take([:port]) |> Keyword.put(:owner, owner)

        case SSH.open(host, Keyword.get(opts, :remote_socket), ssh_opts) do
          {:ok, tunnel} -> {SSH.path(tunnel), tunnel}
          {:error, reason} -> throw({:console, reason})
        end
    end
  end

  # A confirmed command stays successful when the following read fails.
  defp refresh_after_success(model, notice) do
    refresh(%{model | notice: notice})
  catch
    {:console, reason} ->
      disconnect(
        model,
        "#{notice}; reconnect to recover progress: #{Alto.Contrib.Display.error(reason)}"
      )
  end

  defp refresh(model) do
    model = drain(model, 200)
    runs = request(model.client, %{type: "runs"})["runs"]
    sessions = request(model.client, %{type: "sessions"})["sessions"]

    queued =
      command(model.client, "tasks.list", %{
        "session_ids" => Enum.map(sessions, & &1["id"]),
        "ids" => if(model.selected_id, do: [model.selected_id], else: [])
      })

    tasks =
      merge_tasks(sessions, runs, model.opts, model.tasks)
      |> merge_scheduled(queued["tasks"], runs)

    model = %{model | tasks: tasks, tasks_trimmed: queued["truncated"]} |> drain(200)
    model = load_task_detail(model)
    load_history(model)
  end

  defp merge_tasks(sessions, runs, opts, previous) do
    previous = Map.new(previous, &{&1.id, &1})

    stored =
      Map.new(sessions, fn s ->
        workspace = Map.get(previous, s["id"], %{})

        status =
          cond do
            s["runs"] > s["completed_runs"] -> "interrupted"
            s["last_status"] == "ok" -> "completed"
            true -> s["last_status"] || "stored"
          end

        {s["id"],
         %{
           id: s["id"],
           session_id: s["id"],
           run_id: nil,
           title: clean(s["task"] || "Untitled task"),
           status: status,
           config: Keyword.get(opts, :profile, "coding"),
           cwd: s["cwd"] || Map.get(workspace, :cwd),
           workspace_id: Map.get(workspace, :workspace_id),
           workspace_loaded: Map.get(workspace, :workspace_loaded, false),
           usage: %{},
           started_at_ms: s["started_at_ms"] || 0
         }}
      end)

    runs
    |> Enum.reverse()
    |> Enum.reduce(stored, fn r, acc ->
      id = r["session_id"] || r["id"]
      status = if r["pending_approvals"] > 0, do: "waiting", else: r["status"]

      Map.put(acc, id, %{
        id: id,
        session_id: r["session_id"],
        run_id: r["id"],
        title: clean(r["title"] || "Untitled task"),
        status: status,
        config: r["config"],
        cwd: get_in(acc, [id, :cwd]),
        workspace_id: get_in(acc, [id, :workspace_id]),
        workspace_loaded: get_in(acc, [id, :workspace_loaded]) || false,
        usage: r["usage"] || %{},
        started_at_ms: r["started_at_ms"] || 0
      })
    end)
    |> Map.values()
  end

  defp merge_scheduled(stored, scheduled, runs) do
    sessions = MapSet.new(Enum.map(scheduled, & &1["session_id"]))

    direct =
      Enum.reject(
        stored,
        &(MapSet.member?(sessions, &1.session_id) or String.starts_with?(&1.config, "scheduled/"))
      )

    tasks =
      Enum.map(scheduled, fn task ->
        run = Enum.find(runs, &(&1["id"] == task["run_id"]))

        status =
          if run && run["pending_approvals"] > 0 && task["status"] == "running",
            do: "waiting",
            else: task["status"]

        %{
          id: task["id"],
          session_id: task["session_id"],
          run_id: task["run_id"],
          durable: true,
          revision: task["revision"],
          evidence: %{},
          approval: nil,
          upgrade_required: task["upgrade_required"],
          title: clean(task["task"]),
          status: status,
          config: task["profile"],
          workspace_id: task["workspace_id"],
          cwd: task["cwd"],
          usage: (run && run["usage"]) || %{},
          started_at_ms: task["created_at_ms"] || 0
        }
      end)

    Enum.sort_by(tasks ++ direct, &{&1.started_at_ms, &1.id}, :desc)
  end

  defp load_task_detail(model) do
    case selected(model) do
      %{durable: true, id: id} = task ->
        detail = command(model.client, "tasks.get", %{"id" => id})["task"]

        updated = %{
          task
          | title: clean(detail["task"]),
            evidence: detail["evidence"],
            approval: detail["approval"],
            upgrade_required: detail["upgrade_required"],
            usage: detail["evidence"]["usage"] || detail["usage"] || task.usage
        }

        %{
          model
          | tasks: Enum.map(model.tasks, fn item -> if item.id == id, do: updated, else: item end)
        }

      %{workspace_loaded: false, session_id: session, id: id} = task
      when is_binary(session) ->
        project =
          command(model.client, "projects.session", %{session_id: session})["project"]

        updated = %{
          task
          | cwd: project && project["root"],
            workspace_id: project && project["id"],
            workspace_loaded: true
        }

        projects =
          if project,
            do: [project | Enum.reject(model.projects, &(&1["id"] == project["id"]))],
            else: model.projects

        %{
          model
          | tasks:
              Enum.map(model.tasks, fn item -> if item.id == id, do: updated, else: item end),
            projects: projects
        }

      _ ->
        model
    end
  end

  defp load_history(%{selected_id: nil} = model), do: model
  defp load_history(%{client: nil} = model), do: model

  defp load_history(model) do
    session =
      case selected(model) do
        nil -> nil
        task -> task.session_id
      end

    model = if model.history_session_id == session, do: model, else: reset_history(model)

    if is_nil(session),
      do: model,
      else: read_history(%{model | history_session_id: session}, session)
  end

  defp read_history(model, session) do
    page =
      request(model.client, %{
        type: "session_events",
        session_id: session,
        cursor: model.cursor,
        limit: 100
      })

    history = model.history ++ page["events"]

    model = %{
      model
      | history: Enum.take(history, -500),
        cursor: page["last_cursor"],
        history_more: not is_nil(page["next_cursor"]),
        history_gap: model.history_gap or page["gap"],
        history_trimmed: model.history_trimmed or length(history) > 500
    }

    case Client.request(model.client, %{type: "session_transcript", session_id: session}) do
      {:ok, snapshot} ->
        %{model | transcript: snapshot["messages"], transcript_trimmed: snapshot["truncated"]}

      {:error, {:server, _, detail}}
      when detail in ["no_resumable_transcript", ":no_resumable_transcript"] ->
        model

      {:error, reason} ->
        throw({:console, reason})
    end
  catch
    {:console, {:server, "not_found", _} = reason} ->
      case selected(model) do
        %{run_id: run, status: status}
        when not is_nil(run) and status in ["running", "waiting"] ->
          model

        _ ->
          throw({:console, reason})
      end
  end

  defp drain(model, 0), do: model

  defp drain(model, remaining) do
    case Client.next(model.client, 0) do
      {:ok, event} -> model |> notification(event) |> drain(remaining - 1)
      {:error, :timeout} -> model
      {:error, reason} -> throw({:console, reason})
    end
  end

  defp notification(model, %{"type" => "approval_request", "request" => request}),
    do: %{model | approvals: Map.put(model.approvals, request["id"], request)}

  defp notification(model, %{"type" => "approval_resolved", "request" => request}),
    do: %{model | approvals: Map.delete(model.approvals, request["id"])}

  defp notification(model, %{"type" => "result", "run_id" => run}),
    do: %{
      model
      | approvals: Map.reject(model.approvals, fn {_, a} -> a["run_id"] == run end),
        live: Map.delete(model.live, run),
        live_entries: Map.delete(model.live_entries, run)
    }

  defp notification(model, %{"type" => "event", "run_id" => run, "event" => event}) do
    model = %{model | live: Map.put(model.live, run, clean(event["type"]))}

    case event do
      %{"type" => "model_started"} ->
        %{model | live_entries: Map.delete(model.live_entries, run)}

      %{"type" => type, "data" => data}
      when type in ["tool_started", "tool_completed", "tool_failed"] ->
        key = data["operation_id"] || data["call_id"]
        entry = Map.put(Alto.Contrib.ToolDisplay.entry(type, data), :tool_key, key)
        entries = Map.get(model.live_entries, run, [])
        entries = Enum.reject(entries, &(Map.get(&1, :tool_key) == key)) ++ [entry]
        %{model | live_entries: Map.put(model.live_entries, run, Enum.take(entries, -100))}

      %{"type" => type, "data" => %{"text" => text}}
      when type in ["model_delta", "model_reasoning_delta"] and is_binary(text) ->
        kind = if type == "model_delta", do: :assistant, else: :reasoning
        entries = Map.get(model.live_entries, run, [])

        entries =
          case List.pop_at(entries, -1) do
            {%{kind: ^kind} = last, rest} -> rest ++ [%{last | text: clean(last.text <> text)}]
            _ -> entries ++ [%{kind: kind, text: clean(text)}]
          end

        %{model | live_entries: Map.put(model.live_entries, run, Enum.take(entries, -100))}

      _ ->
        model
    end
  end

  defp notification(_model, %{"type" => "overflow"} = event),
    do: throw({:console, {:notification_overflow, event["run_id"], event["domain"]}})

  defp notification(model, _), do: model

  defp new_task(model, workspace_id, workspace_root, notice) do
    reset_history(%{
      model
      | selected_id: nil,
        workspace_id: workspace_id,
        workspace_root: workspace_root,
        notice: notice
    })
  end

  defp reset_history(model),
    do: %{
      model
      | history: [],
        history_session_id: nil,
        cursor: 0,
        transcript: [],
        entries: [],
        history_gap: false,
        history_trimmed: false,
        transcript_trimmed: false,
        history_more: false
    }

  defp present(model) do
    task = selected(model)

    conversation = Alto.Contrib.ToolDisplay.transcript(model.transcript)

    activity = Enum.flat_map(model.history, &List.wrap(history_entry(&1, conversation == [])))
    live = if task, do: Map.get(model.live_entries, task.run_id, []), else: []

    live =
      Enum.reject(live, fn entry ->
        Enum.any?(
          Enum.take(conversation, -2),
          &(to_string(&1.kind) == to_string(entry.kind) and &1.text == entry.text)
        )
      end)

    entries = conversation ++ activity ++ live

    entries = if entries == [] and task, do: [%{kind: :user, text: task.title}], else: entries

    notices =
      []
      |> flag(model.tasks_trimmed, "Showing latest scheduled tasks and visible conversations")
      |> flag(model.history_gap, "History has a gap; reconnect to reload")
      |> flag(model.history_more, "Loading older activity…")
      |> flag(model.history_trimmed, "Showing the latest 500 activity records")
      |> flag(model.transcript_trimmed, "Showing the latest 100 conversation messages")

    entries = Enum.map(notices, &%{kind: :notice, text: &1}) ++ entries

    detail =
      if task do
        usage = Alto.Usage.normalize(task.usage)

        approval =
          case selected_approvals(model) do
            [] ->
              ""

            [a | rest] ->
              "\nDecision: #{clean(a["tool"])}\n#{clean(a["arguments"])}\n#{clean(a["details"])}\nApprove or deny the exact pending action\n#{length(rest)} more pending"
          end

        review =
          if task.status == "requires_operator" do
            "\nReview: #{clean(Map.get(task, :evidence))}\nOperator decision: committed, failed or permitted retry with an explanatory note"
          else
            ""
          end

        upgrade =
          if Map.get(task, :upgrade_required),
            do:
              "\nUpgrade: resolve this approval with the previous version, or cancel after reviewing completed effects.",
            else: ""

        "#{task.status}\nTask: #{task.id}\nProfile: #{clean(task.config)}\nSession: #{task.session_id}\nRun: #{task.run_id || "not resident"}\nUsage: #{clean(task.usage)}\nCache: #{Float.round(Alto.Usage.last_cache_hit_rate(usage), 1)}% last / #{Float.round(Alto.Usage.cache_hit_rate(usage), 1)}% total\n#{Map.get(model.live, task.run_id, "")}#{approval}#{review}#{upgrade}"
      else
        "New task\nProfile: #{clean(Keyword.get(model.opts, :profile, "coding"))}"
      end

    folder =
      if task,
        do: Map.get(task, :cwd) || "Unknown · open a workspace before starting a new task",
        else: model.workspace_root || "Service default"

    %{
      model
      | entries: entries,
        detail: "Workspace folder\n" <> clean(folder) <> "\n^G W Change folder\n\n" <> detail
    }
  end

  defp history_entry(%{"event" => "model_completed", "data" => data}, true),
    do:
      Alto.Contrib.Reasoning.entries(%{"reasoning" => data["reasoning"]}) ++
        [%{kind: :assistant, text: clean(data["message"])}]

  defp history_entry(%{"event" => "model_completed"}, false), do: nil

  defp history_entry(%{"event" => event, "data" => data}, empty?)
       when event in ["tool_completed", "tool_failed"] do
    if empty?, do: Alto.Contrib.ToolDisplay.entry(event, data)
  end

  defp history_entry(%{"event" => event, "data" => data}, _) do
    %{
      kind: :activity,
      text: Alto.Contrib.Display.label(event) <> ": " <> Alto.Contrib.Display.result(data)
    }
  end

  defp selected(model), do: Enum.find(model.tasks, &(&1.id == model.selected_id))

  defp selected_approvals(model) do
    case selected(model) do
      %{upgrade_required: reason} when is_binary(reason) -> []
      %{status: "waiting_approval", approval: approval} when is_map(approval) -> [approval]
      _ -> live_approvals(model)
    end
  end

  defp live_approvals(model) do
    run =
      case selected(model) do
        nil -> nil
        task -> task.run_id
      end

    model.approvals
    |> Map.values()
    |> Enum.filter(&(&1["run_id"] == run))
    |> Enum.sort_by(& &1["id"])
  end

  defp command(client, name, payload),
    do: request(client, %{type: "command", name: name, payload: payload})

  defp request(client, command) do
    case Client.request(client, command) do
      {:ok, reply} -> reply
      {:error, reason} -> throw({:console, reason})
    end
  end

  defp failed(model, {:create_workspace, _}, {:server, _, _} = reason),
    do: %{model | notice: "Could not create folder: #{Alto.Contrib.Display.error(reason)}"}

  defp failed(model, {:workspace, _path}, {:server, _, _} = reason) do
    detail = Alto.Contrib.Display.error(reason)

    notice =
      cond do
        String.contains?(detail, "Folder does not exist or is not a directory") ->
          "Folder does not exist or is not a directory on the service host."

        String.contains?(detail, "Enter a folder path on one line") ->
          "Enter a folder path on one line."

        true ->
          "Could not open workspace: #{Alto.Contrib.Display.error(reason)}"
      end

    %{model | notice: notice}
  end

  defp failed(model, :efforts, {:server, _, _} = reason),
    do: %{
      model
      | effort_catalog: nil,
        notice: "Could not load effort choices: #{Alto.Contrib.Display.error(reason)}"
    }

  defp failed(model, action, {:server, _, _} = reason) when action != :connect,
    do: %{model | notice: "Request rejected: #{Alto.Contrib.Display.error(reason)}"}

  defp failed(model, action, reason) do
    suffix =
      if match?({:submit, _}, action),
        do: "; send outcome unknown—reconnect and inspect before resending",
        else: "; reconnect to inspect server state"

    disconnect(model, Alto.Contrib.Display.error(reason) <> suffix)
  end

  defp disconnect(model, notice) do
    close(model)
    %{model | client: nil, tunnel: nil, connection: "disconnected", notice: notice}
  end

  defp flag(list, true, text), do: list ++ [text]
  defp flag(list, _, _), do: list

  @doc "Bound display values and remove terminal control characters."
  def clean(value) do
    text =
      cond do
        is_binary(value) -> value
        is_nil(value) -> ""
        true -> Alto.Contrib.Display.result(value)
      end

    text = clean_input(text)

    if String.length(text) > 8_000,
      do: String.slice(text, 0, 8_000) <> "… [truncated]",
      else: text
  end

  @doc false
  def clean_input(text), do: String.replace(text, ~r/[\x00-\x08\x0B-\x1F\x7F-\x9F]/u, "")
end
