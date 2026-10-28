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

  @doc "Start a configured resident service and wait for its termination."
  def serve(%Config{} = config) do
    with {:ok, pid} <- Service.start(config) do
      IO.puts(:stderr, "alto: resident service at #{Config.socket_path(config)}")
      monitor = Process.monitor(pid)

      receive do
        {:DOWN, ^monitor, :process, ^pid, reason} -> {:error, {:service_stopped, reason}}
      end
    end
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
    with {:ok, config} <- Config.load(path), do: serve(config)
  end

  defp dispatch(args, opts) do
    with {:ok, command} <- command(args, opts),
         {:ok, client} <- connect(opts) do
      try do
        with {:ok, reply} <- Client.request(client, command) do
          if command["type"] == "attach", do: watch(client), else: print(reply)
        end
      after
        Client.close(client)
      end
    end
  end

  @wire_commands %{
    "status" => {:sessions, [], []},
    "start" => {:start_run, [:config, :task], []},
    "follow" => {:start_run, [:resume, :config, :task], []},
    "history" => {:session_events, [:session_id], [cursor: 0]},
    "watch" => {:attach, [:run_id], [from_seq: 1]},
    "cancel" => {:cancel, [:run_id], [reason: "user"]},
    "tasks" => {"tasks.list", [], []},
    "workspaces" => {"workspaces.list", [], [cursor: 0]},
    "workspace" => {"workspaces.get", [:id], []},
    "workspace-patch" => {"workspaces.patch", [:id], [cursor: 0]},
    "team-batches" => {"children.list", [], [cursor: 0]},
    "team-batch" => {"children.get", [:key], []},
    "team-result" =>
      {"children.result", [:key, :child], [generation: nil, revision: nil, cursor: 0]},
    "mailbox" => {"mailbox.list", [:root], [cursor: 0]},
    "mailbox-compact" => {"mailbox.compact", [], []},
    "mailbox-get" => {"mailbox.get", [:root, :key], []},
    "mailbox-cancel" => {"mailbox.cancel", [:root, :key], []},
    "task" => {"tasks.get", [:id], []},
    "task-cancel" => {"tasks.cancel", [:id], []},
    "workspace-discard" => {"workspaces.discard", [:id], [revision: nil, note: nil]},
    "team-child-approval" =>
      {"children.approval", [:key, :child], [generation: nil, revision: nil]},
    "task-decide" => {"tasks.decide", [:id, :decision], [revision: nil]},
    "task-child-decide" =>
      {"tasks.child_decide", [:id, :child, :decision],
       [
         revision: nil,
         generation: nil,
         batch_revision: nil,
         attempt: nil,
         suspension: nil,
         key: nil
       ]},
    "task-cleanup" => {"tasks.cleanup", [:id], [revision: nil]},
    "task-reconcile" => {"tasks.reconcile", [:id, :resolution], [revision: nil, note: nil]},
    "task-recover" =>
      {"tasks.recover", [:id, :key], [revision: nil, generation: nil, continuation_revision: nil]}
  }

  defp command(["schedule", profile, task], opts) do
    payload = %{"profile" => profile, "task" => task}
    payload = maybe_put(payload, "id", Keyword.get(opts, :id))
    payload = maybe_put(payload, "delay_ms", Keyword.get(opts, :delay_ms))
    {:ok, command_wire("tasks.submit", payload)}
  end

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
      {wire, keys, defaults} when length(args) == length(keys) ->
        fields =
          Enum.zip(keys, args) ++
            Enum.map(defaults, fn {key, default} ->
              {key, Keyword.get(opts, key, default)}
            end)

        case Enum.find(fields, fn {key, value} -> not valid_argument?(key, value) end) do
          nil ->
            {:ok, command_wire(wire, Map.new(fields, fn {k, v} -> {Atom.to_string(k), v} end))}

          {key, _} ->
            {:error, {:invalid_argument, key}}
        end

      _ ->
        {:error, :invalid_command}
    end
  end

  defp command(_, _), do: {:error, :invalid_command}

  defp valid_argument?(key, value)
       when key in [:revision, :batch_revision, :continuation_revision, :from_seq],
       do: is_integer(value) and value > 0

  defp valid_argument?(:cursor, value), do: is_integer(value) and value >= 0
  defp valid_argument?(:decision, value), do: value in ["approve", "deny"]
  defp valid_argument?(:resolution, value), do: value in ["committed", "failed", "retry"]
  defp valid_argument?(_key, value), do: is_binary(value) and String.trim(value) != ""

  defp command_wire(type, payload) when is_atom(type),
    do: Map.put(payload, "type", Atom.to_string(type))

  defp command_wire(name, payload),
    do: %{"type" => "command", "name" => name, "payload" => payload}

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

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
