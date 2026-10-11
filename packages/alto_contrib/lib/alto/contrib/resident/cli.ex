defmodule Alto.Contrib.Resident.CLI do
  @moduledoc "Command-line access to the resident service."

  alias Alto.Contrib.Socket.Client
  alias Alto.Contrib.Resident.{Config, Service}

  @help """
  Alto resident service

  alto resident serve CONFIG.exs
  alto resident status [--socket PATH]
  alto resident start PROFILE TASK [--socket PATH]
  alto resident follow SESSION PROFILE TASK [--socket PATH]
  alto resident watch RUN [--from-seq N] [--socket PATH]
  alto resident history SESSION [--cursor N] [--socket PATH]
  alto resident cancel RUN [--socket PATH]
  alto resident approve REQUEST [--socket PATH]
  alto resident deny REQUEST [--socket PATH]
  alto resident schedule PROFILE TASK [--delay-ms N] [--id KEY] [--socket PATH]
  alto resident tasks [--socket PATH]
  alto resident task ID [--socket PATH]
  alto resident task-cancel ID [--socket PATH]
  alto resident task-reconcile ID committed|failed|retry --revision N --note TEXT [--socket PATH]
  alto resident task-decide ID approve|deny --revision N [--socket PATH]
  alto resident task-child-decide TASK CHILD approve|deny --revision TASK_REV --generation BATCH_GEN --batch-revision BATCH_REV --attempt ATTEMPT --suspension NONCE --key BATCH_KEY [--socket PATH]
  alto resident task-cleanup TASK --revision TASK_REV [--socket PATH]
  alto resident task-recover ID KEY --revision TASK_REV --generation G --continuation-revision CELL_REV [--socket PATH]
  alto resident mailbox-compact [--socket PATH]
  alto resident mailbox ROOT_RUN_ID [--cursor N] [--socket PATH]
  alto resident mailbox-get ROOT_RUN_ID MESSAGE_KEY [--socket PATH]
  alto resident mailbox-cancel ROOT_RUN_ID MESSAGE_KEY [--socket PATH]
  alto resident workspaces [--cursor N] [--socket PATH]
  alto resident workspace ID [--socket PATH]
  alto resident workspace-patch ID [--cursor N] [--socket PATH]
  alto resident workspace-discard ID --revision N --note TEXT [--socket PATH]
  alto resident team-batches [--cursor N] [--socket PATH]
  alto resident team-batch KEY [--socket PATH]
  alto resident team-result KEY CHILD --generation G --revision N [--cursor N] [--socket PATH]
  alto resident team-child-approval KEY CHILD --generation G --revision N [--socket PATH]

  Serve owns execution. Closing status/watch clients does not stop agents.
  Configuration is trusted Elixir code. Use SSH socket forwarding for remote access.
  """

  def main(args) do
    case run(args) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "alto resident: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def run(args) do
    with {:ok, _} <- Application.ensure_all_started(:alto_contrib), do: run_started(args)
  end

  defp run_started(args) do
    {opts, args, invalid} =
      OptionParser.parse(
        args,
        strict: [
          socket: :string,
          from_seq: :integer,
          cursor: :integer,
          delay_ms: :integer,
          id: :string,
          revision: :integer,
          continuation_revision: :integer,
          batch_revision: :integer,
          note: :string,
          generation: :string,
          attempt: :string,
          suspension: :string,
          key: :string
        ]
      )

    if invalid == [] do
      dispatch(args, opts)
    else
      {:error, {:invalid_options, invalid}}
    end
  end

  defp dispatch([], _opts), do: IO.puts(@help)
  defp dispatch(["help"], _opts), do: IO.puts(@help)

  defp dispatch(["serve", path], _opts) do
    with {:ok, config} <- Config.load(path),
         {:ok, pid} <- Service.start(config) do
      IO.puts("Alto is listening at #{Config.socket_path(config)}")
      monitor = Process.monitor(pid)

      receive do
        {:DOWN, ^monitor, :process, ^pid, reason} -> {:error, {:service_stopped, reason}}
      end
    end
  end

  defp dispatch(["watch", run], opts) do
    with {:ok, client} <- connect(opts) do
      try do
        with {:ok, _} <-
               Client.request(client, %{
                 "type" => "attach",
                 "run_id" => run,
                 "from_seq" => Keyword.get(opts, :from_seq, 1)
               }),
             do: watch(client)
      after
        Client.close(client)
      end
    end
  end

  defp dispatch(args, opts) do
    with {:ok, command} <- command(args, opts),
         {:ok, client} <- connect(opts) do
      try do
        case Client.request(client, command) do
          {:ok, reply} -> print(reply)
          {:error, reason} -> {:error, reason}
        end
      after
        Client.close(client)
      end
    end
  end

  @wire_commands %{
    "tasks" => {"tasks.list", [], false},
    "workspaces" => {"workspaces.list", [], true},
    "workspace" => {"workspaces.get", ["id"], false},
    "workspace-patch" => {"workspaces.patch", ["id"], true},
    "team-batches" => {"children.list", [], true},
    "team-batch" => {"children.get", ["key"], false},
    "mailbox" => {"mailbox.list", ["root"], true},
    "mailbox-compact" => {"mailbox.compact", [], false},
    "mailbox-get" => {"mailbox.get", ["root", "key"], false},
    "mailbox-cancel" => {"mailbox.cancel", ["root", "key"], false},
    "task" => {"tasks.get", ["id"], false},
    "task-cancel" => {"tasks.cancel", ["id"], false},
    "workspace-discard" =>
      {"workspaces.discard", ["id"], [:revision, :note],
       :workspace_discard_requires_revision_and_note},
    "team-child-approval" =>
      {"children.approval", ["key", "child"], [:generation, :revision],
       :team_child_approval_requires_generation_and_revision},
    "task-decide" =>
      {"tasks.decide", ["id", "decision"], [:revision], {:invalid_task_decide, :revision}},
    "task-child-decide" =>
      {"tasks.child_decide", ["id", "child", "decision"],
       [:revision, :generation, :batch_revision, :attempt, :suspension, :key],
       :invalid_task_child_decide},
    "task-cleanup" => {"tasks.cleanup", ["id"], [:revision], :task_cleanup_requires_revision},
    "task-recover" =>
      {"tasks.recover", ["id", "key"], [:revision, :generation, :continuation_revision],
       :invalid_parent_recovery_request}
  }
  @positive_keys ~w(revision batch_revision continuation_revision)

  defp command(["status"], _), do: {:ok, %{"type" => "sessions"}}

  defp command(["start", profile, task], _),
    do: {:ok, %{"type" => "start_run", "config" => profile, "task" => task}}

  defp command(["follow", session, profile, task], _),
    do: {:ok, %{"type" => "start_run", "config" => profile, "task" => task, "resume" => session}}

  defp command(["history", session], opts),
    do:
      {:ok,
       %{
         "type" => "session_events",
         "session_id" => session,
         "cursor" => Keyword.get(opts, :cursor, 0)
       }}

  defp command(["cancel", run], _),
    do: {:ok, %{"type" => "cancel", "run_id" => run, "reason" => "user"}}

  defp command(["schedule", profile, task], opts) do
    payload = %{"profile" => profile, "task" => task}
    payload = maybe_put(payload, "id", Keyword.get(opts, :id))
    payload = maybe_put(payload, "delay_ms", Keyword.get(opts, :delay_ms))
    {:ok, command_wire("tasks.submit", payload)}
  end

  defp command(["team-result", key, child], opts) do
    generation = Keyword.get(opts, :generation)
    revision = Keyword.get(opts, :revision)
    cursor = Keyword.get(opts, :cursor, 0)

    cond do
      not nonempty?(generation) or not positive?(revision) ->
        {:error, :team_result_requires_generation_and_revision}

      not (is_integer(cursor) and cursor >= 0) ->
        {:error, {:invalid_team_result, :cursor}}

      true ->
        {:ok,
         command_wire("children.result", %{
           "key" => key,
           "child" => child,
           "generation" => generation,
           "revision" => revision,
           "cursor" => cursor
         })}
    end
  end

  defp command(["task-reconcile", id, resolution], opts)
       when resolution in ["committed", "failed", "retry"] do
    revision = Keyword.get(opts, :revision)
    note = Keyword.get(opts, :note)

    cond do
      not positive?(revision) ->
        {:error, {:invalid_task_reconcile, :revision}}

      not nonempty?(note) ->
        {:error, {:invalid_task_reconcile, :note}}

      true ->
        {:ok,
         command_wire("tasks.reconcile", %{
           "id" => id,
           "resolution" => resolution,
           "revision" => revision,
           "note" => note
         })}
    end
  end

  defp command(["task-decide", _id, decision], _opts)
       when decision not in ["approve", "deny"],
       do: {:error, {:invalid_task_decide, :decision}}

  defp command(["task-child-decide", _task, _child, decision], _opts)
       when decision not in ["approve", "deny"],
       do: {:error, {:invalid_task_child_decide, :decision}}

  defp command([decision, request], _) when decision in ["approve", "deny"],
    do:
      {:ok,
       %{
         "type" => "approval_response",
         "request_id" => request,
         "decision" => if(decision == "approve", do: "approve", else: %{"deny" => "user"})
       }}

  defp command([name | args], opts) do
    case Map.get(@wire_commands, name) do
      {wire, keys, cursor?} when length(args) == length(keys) ->
        payload = Map.new(Enum.zip(keys, args))

        payload =
          if cursor?,
            do: Map.put(payload, "cursor", Keyword.get(opts, :cursor, 0)),
            else: payload

        {:ok, command_wire(wire, payload)}

      {wire, keys, required, error} when length(args) == length(keys) ->
        if name == "task-recover" and not Enum.all?(args, &nonempty?/1) do
          {:error, error}
        else
          checked_wire(wire, Map.new(Enum.zip(keys, args)), opts, required, error)
        end

      _ ->
        {:error, :invalid_command}
    end
  end

  defp command(_, _), do: {:error, :invalid_command}

  defp checked_wire(wire, base, opts, keys, error) do
    values = Map.new(keys, fn key -> {Atom.to_string(key), Keyword.get(opts, key)} end)

    valid? =
      Enum.all?(values, fn {key, value} ->
        if key in @positive_keys, do: positive?(value), else: nonempty?(value)
      end)

    if valid?, do: {:ok, command_wire(wire, Map.merge(base, values))}, else: {:error, error}
  end

  defp command_wire(name, payload),
    do: %{"type" => "command", "name" => name, "payload" => payload}

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp positive?(value), do: is_integer(value) and value > 0
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp connect(opts) do
    path = Keyword.get(opts, :socket, Path.join(Config.default_state_dir(), "service.sock"))
    Client.connect(path)
  end

  defp watch(client) do
    case Client.next(client, 30_000) do
      {:ok, %{"type" => "result"} = event} ->
        print(event)

      {:ok, event} ->
        print(event)
        watch(client)

      {:error, :timeout} ->
        watch(client)

      {:error, reason} ->
        {:error, {:disconnected, reason}}
    end
  end

  defp print(value), do: value |> JSON.encode!() |> IO.puts()
end
