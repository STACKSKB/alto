defmodule Alto.FrontEnd.RegistrySessionsTest do
  @moduledoc """
  : explicit served-agent session persistence and resume.

  Registry-started runs persist (transcript continuity + audit facts) only
  when the operator opts in; resume reuses the named session verbatim.
  Inbox ownership stays in the queue and operation recovery in the ledger —
  resume touches neither. A saved transcript is continuity, not workflow
  replay: crashed runs report their state instead of rerunning effects.
  """

  use ExUnit.Case, async: true

  alias Alto.FrontEnd.Registry
  alias Alto.Listeners.Connection

  @receive_timeout 5_000

  defmodule EchoTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :echo
    @impl true
    def schema do
      %{
        description: "Echo a value.",
        parameters: %{
          type: "object",
          properties: %{value: %{type: "string"}},
          required: ["value"]
        }
      }
    end

    @impl true
    def execution_mode, do: :parallel
    @impl true
    def approval, do: :never
    @impl true
    def run(%{"value" => value}, _context), do: {:ok, %{echo: value}}
  end

  defmodule CountingTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :echo
    @impl true
    def schema, do: EchoTool.schema()
    @impl true
    def execution_mode, do: :parallel
    @impl true
    def approval, do: :never
    @impl true
    def run(%{"value" => value}, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:tool_ran, value})
      {:ok, %{echo: value}}
    end
  end

  defmodule ToolThenAnswerProvider do
    @behaviour Alto.Provider
    @impl true
    def describe(_opts), do: %{}
    @impl true
    def stream(request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_request, request})

      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        {:ok, %{message: "finished", tool_calls: []}}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [%{id: "call-1", name: "echo", arguments_json: ~s({"value":"hello"})}]
         }}
      end
    end
  end

  defmodule SecretProvider do
    @behaviour Alto.Provider
    @impl true
    def describe(_opts), do: %{}
    @impl true
    def stream(_request, _sink, _opts), do: {:ok, %{message: "done", tool_calls: []}}
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider
    @impl true
    def describe(_opts), do: %{}
    @impl true
    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), :child_entered)
      receive(do: (:never -> {:ok, %{message: nil, tool_calls: []}}))
    end
  end

  defmodule SpawnOnceLoop do
    @behaviour Alto.Loop
    @impl true
    def init(%{spawn: spawn}, _spec),
      do: Alto.Transition.continue(%{}, [Alto.Effect.spawn_agent(spawn)])

    @impl true
    def handle_event(%Alto.Event{type: :subagent_completed, data: data}, s, _spec),
      do: Alto.Transition.stop(s, {:completed, data})

    def handle_event(%Alto.Event{type: :subagent_failed, data: data}, s, _spec),
      do: Alto.Transition.stop(s, {:failed, data})

    def handle_event(_event, state, _spec), do: Alto.Transition.continue(state)
  end

  defmodule SpawnBlockerLoop do
    @moduledoc false
    # Delegates to a blocking child; the binary task is opaque so the loop
    # works over the string-task registry boundary.
    @behaviour Alto.Loop
    @impl true
    def init(_task, spec) do
      test_pid = Keyword.fetch!(spec.driver_options, :test_pid)

      Alto.Transition.continue(%{}, [
        Alto.Effect.spawn_agent(%{
          id: "sub-1",
          task: "child",
          provider: {BlockingProvider, test_pid: test_pid}
        })
      ])
    end

    @impl true
    def handle_event(%Alto.Event{type: :subagent_completed, data: data}, s, _spec),
      do: Alto.Transition.stop(s, {:completed, data})

    def handle_event(%Alto.Event{type: :subagent_failed, data: data}, s, _spec),
      do: Alto.Transition.stop(s, {:failed, data})

    def handle_event(_event, state, _spec), do: Alto.Transition.continue(state)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-served-sess-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, session_dir: Path.join(root, "sessions")}
  end

  defp start_registry(name, session_opts, resolver, extra \\ []) do
    id = :"registry-sup-#{System.unique_integer([:positive])}"

    opts =
      [name: name, config_resolver: resolver, cwd: File.cwd!()] ++
        session_opts ++ extra

    start_supervised!(%{id: id, start: {Registry, :start_link, [opts]}})
    name
  end

  defp tool_resolver(parent) do
    fn
      "tool-loop" ->
        {:ok,
         [
           provider: {ToolThenAnswerProvider, test_pid: parent},
           tools: [EchoTool],
           approval: Alto.Approvals.DenyAll
         ]}

      other ->
        {:error, {:unknown_config, other}}
    end
  end

  defp wait_empty(registry) do
    wait_until(fn -> Registry.run_ids(registry) == [] end)
  end

  defp wait_until(fun, attempts \\ 400) do
    if fun.() do
      :ok
    else
      if attempts == 0,
        do: flunk("condition not met"),
        else:
          (
            Process.sleep(10)
            wait_until(fun, attempts - 1)
          )
    end
  end

  defp attach_collect(registry, run_id) do
    :ok = Registry.attach(registry, self(), run_id, 1, [:durable, :live])
    client = self()
    puller = spawn(fn -> pull_loop(registry, client) end)
    result = collect_until_result(run_id)
    Process.exit(puller, :kill)
    Registry.detach(registry, self())
    result
  end

  defp pull_loop(registry, client) do
    Registry.pull(registry, client, 100)
    Process.sleep(5)
    pull_loop(registry, client)
  end

  defp collect_until_result(run_id) do
    receive do
      {:alto_notification, {:result, ^run_id, outcome, output, _}} -> {outcome, output}
      {:alto_notification, _other} -> collect_until_result(run_id)
    after
      @receive_timeout -> flunk("no result for #{run_id}")
    end
  end

  defp drain(mailbox_tag) do
    receive do
      msg when is_tuple(msg) and elem(msg, 0) == mailbox_tag -> [msg | drain(mailbox_tag)]
    after
      0 -> []
    end
  end

  describe "served persistence and resume" do
    test "a completed served run persists and resumes after restart", %{session_dir: dir} do
      parent = self()
      registry = :"sess-reg-#{System.unique_integer([:positive])}"

      resolver = fn
        "tool-loop" ->
          {:ok,
           [
             provider: {ToolThenAnswerProvider, test_pid: parent},
             tools: [{CountingTool, test_pid: parent}],
             approval: Alto.Approvals.AllowAll
           ]}

        other ->
          {:error, {:unknown_config, other}}
      end

      start_registry(registry, [sessions: [session_dir: dir]], resolver)

      {:ok, run_id} = Registry.start_run(registry, "tool-loop", "first task")
      assert {:ok, "finished"} = attach_collect(registry, run_id)
      assert_received {:tool_ran, "hello"}

      session_id = Registry.run_session(registry, run_id)
      assert is_binary(session_id)

      # Transcript continuity: the snapshot holds the full first run.
      assert {:ok, %{messages: messages}} = Alto.Session.transcript(session_id, session_dir: dir)
      assert Enum.any?(messages, &(&1["role"] == "tool"))

      # Root summary over the audit log.
      assert {:ok, [summary]} = Registry.sessions(registry)
      assert summary.id == session_id
      assert summary.completed_runs == 1
      assert summary.last_outcome == "ok"

      # Server restart: same directory, new registry, session discoverable.
      GenServer.stop(registry)
      registry2 = :"sess-reg-#{System.unique_integer([:positive])}"
      start_registry(registry2, [sessions: [session_dir: dir]], resolver)

      assert {:ok, [summary2]} = Registry.sessions(registry2)
      assert summary2.id == session_id

      # Resume continues the transcript without rerunning the tool.
      {:ok, run_id2} = Registry.start_run(registry2, "tool-loop", "thanks", resume: session_id)
      assert {:ok, "finished"} = attach_collect(registry2, run_id2)

      tool_runs = drain(:tool_ran)
      assert tool_runs == []

      assert {:ok, %{messages: messages2}} = Alto.Session.transcript(session_id, session_dir: dir)
      assert length(messages2) > length(messages)
      assert List.last(messages2)["role"] in ["assistant", "user"]

      assert {:ok, [summary3]} = Registry.sessions(registry2)
      assert summary3.runs == 2
      assert summary3.completed_runs == 2
      assert summary3.last_outcome == "ok"
    end

    test "unpersisted served runs stay unpersisted by default", %{session_dir: dir} do
      parent = self()
      registry = :"sess-reg-#{System.unique_integer([:positive])}"
      # Sessions disabled, but point reads at an isolated directory so the
      # assertion is hermetic regardless of the ambient state home.
      start_registry(registry, [session_dir: dir], tool_resolver(parent))

      {:ok, run_id} = Registry.start_run(registry, "tool-loop", "task")
      assert {:ok, "finished"} = attach_collect(registry, run_id)

      assert Registry.run_session(registry, run_id) == nil
      assert {:ok, []} = Registry.sessions(registry)
      # Nothing was ever written for this directory.
      assert File.ls(dir) == {:error, :enoent}
    end
  end

  describe "crash honesty" do
    test "a killed run reports no resumable transcript and never reruns", %{session_dir: dir} do
      parent = self()
      registry = :"sess-reg-#{System.unique_integer([:positive])}"

      resolver = fn
        "tool-loop" ->
          {:ok,
           [
             provider: {ToolThenAnswerProvider, test_pid: parent},
             tools: [{CountingTool, test_pid: parent}],
             approval: Alto.Approvals.AllowAll
           ]}

        other ->
          {:error, {:unknown_config, other}}
      end

      start_registry(registry, [sessions: [session_dir: dir]], resolver)

      {:ok, run_id} = Registry.start_run(registry, "tool-loop", "doomed task")
      assert_receive {:tool_ran, "hello"}, @receive_timeout

      # Crash the run mid-flight: no snapshot, no completed record.
      %{handle: handle} = :sys.get_state(registry).runs[run_id]
      pid = Alto.Test.Runner.worker(handle)
      Process.exit(pid, :kill)
      wait_empty(registry)

      # Drain everything the dead run emitted; from here it is silent.
      _ = drain(:tool_ran)
      _ = drain(:provider_request)

      session_id = Registry.run_session(registry, run_id)
      assert is_binary(session_id)

      # The actual recoverable state: audit facts exist, nothing resumable.
      assert {:ok, records} = Alto.Session.read(session_id, session_dir: dir)
      assert Enum.any?(records, &(&1["type"] == "started"))
      refute Enum.any?(records, &(&1["type"] == "completed"))

      assert {:error, :no_resumable_transcript} =
               Alto.Session.transcript(session_id, session_dir: dir)

      assert {:error, :no_resumable_transcript} =
               Registry.start_run(registry, "tool-loop", "retry", resume: session_id)

      # Nothing reran after the failed resume.
      assert drain(:tool_ran) == []
      assert drain(:provider_request) == []

      assert {:ok, [summary]} = Registry.sessions(registry)
      assert summary.completed_runs == 0
      assert summary.last_outcome == nil
    end
  end

  describe "children under cancellation" do
    test "a cancelled child finalizes its audit; the root keeps its snapshot", %{
      session_dir: dir
    } do
      parent = self()
      registry = :"sess-reg-#{System.unique_integer([:positive])}"

      parent_loop =
        Alto.loop(SpawnBlockerLoop,
          test_pid: parent,
          subagents: Alto.Subagents.bounded(max_depth: 1)
        )

      resolver = fn
        "spawn-loop" ->
          {:ok,
           [
             loop: parent_loop,
             provider: {ToolThenAnswerProvider, test_pid: parent},
             tools: [],
             approval: Alto.Approvals.DenyAll
           ]}

        other ->
          {:error, {:unknown_config, other}}
      end

      start_registry(registry, [sessions: [session_dir: dir]], resolver)

      {:ok, run_id} = Registry.start_run(registry, "spawn-loop", "delegate and block")
      assert_receive :child_entered, @receive_timeout

      assert :ok = Registry.cancel(registry, run_id, :operator_stop)
      wait_empty(registry)

      session_id = Registry.run_session(registry, run_id)

      assert {:ok, records} = Alto.Session.read(session_id, session_dir: dir)

      child_started =
        Enum.find(records, &(&1["type"] == "started" and &1["subagent"] == true))

      assert child_started["parent_run_id"] == run_id

      child_completed =
        Enum.find(
          records,
          &(&1["type"] == "completed" and &1["subagent"] == true and
              &1["run_id"] == child_started["run_id"])
        )

      assert child_completed["outcome"] == "cancelled"

      # Root snapshot ownership: the transcript holds only the root run's
      # single user message — the child never overwrote it.
      assert {:ok, %{messages: [single]}} = Alto.Session.transcript(session_id, session_dir: dir)
      assert single["role"] == "user"
    end
  end

  describe "eviction, storage, and secrets" do
    test "an evicted run stays resumable from disk", %{session_dir: dir} do
      parent = self()
      registry = :"sess-reg-#{System.unique_integer([:positive])}"

      start_registry(
        registry,
        [sessions: [session_dir: dir]],
        tool_resolver(parent),
        max_finished_runs: 1
      )

      {:ok, first} = Registry.start_run(registry, "tool-loop", "first")
      assert {:ok, "finished"} = attach_collect(registry, first)
      first_session = Registry.run_session(registry, first)

      {:ok, _second} = Registry.start_run(registry, "tool-loop", "second")
      wait_empty(registry)

      # Evicted from the replay window...
      assert {:error, :unknown_run} = Registry.attach(registry, self(), first, 1, [:durable])

      # ...yet resumable with its transcript intact.
      {:ok, resumed} =
        Registry.start_run(registry, "tool-loop", "follow-up", resume: first_session)

      assert {:ok, "finished"} = attach_collect(registry, resumed)
      assert Registry.run_session(registry, resumed) == first_session
    end

    test "unavailable storage never fails the run", %{root: root} do
      parent = self()
      registry = :"sess-reg-#{System.unique_integer([:positive])}"
      blocker = Path.join(root, "file-not-dir")
      File.write!(blocker, "x")

      start_registry(registry, [sessions: [session_dir: blocker]], tool_resolver(parent))

      {:ok, run_id} = Registry.start_run(registry, "tool-loop", "task")
      assert {:ok, "finished"} = attach_collect(registry, run_id)
    end

    test "persisted records carry no credentials", %{session_dir: dir} do
      registry = :"sess-reg-#{System.unique_integer([:positive])}"

      resolver = fn
        "secret-loop" ->
          {:ok,
           [
             provider: {SecretProvider, api_key: "sk-test-SECRET-xyz", model: "m"},
             tools: [],
             approval: Alto.Approvals.DenyAll
           ]}

        other ->
          {:error, {:unknown_config, other}}
      end

      start_registry(registry, [sessions: [session_dir: dir]], resolver)

      {:ok, run_id} = Registry.start_run(registry, "secret-loop", "harmless task")
      assert {:ok, "done"} = attach_collect(registry, run_id)

      files = Path.wildcard(Path.join(dir, "**/*")) |> Enum.filter(&File.regular?/1)
      assert files != []

      for path <- files do
        refute File.read!(path) =~ "sk-test-SECRET-xyz",
               "secret leaked into #{path}"
      end
    end

    test "resume leaves inbox work untouched", %{session_dir: dir} do
      parent = self()
      registry = :"sess-reg-#{System.unique_integer([:positive])}"
      queue = :"sess-queue-#{System.unique_integer([:positive])}"
      {:ok, _} = Alto.Queue.start_link(id: "sess-q", dir: Path.join(dir, "q"), name: queue)

      start_registry(registry, [sessions: [session_dir: dir]], tool_resolver(parent),
        queue: queue
      )

      {:ok, _} = Alto.Queue.admit(queue, "src:del-1", %{"body" => "x"})
      assert %{pending: 1} = Alto.Queue.count(queue)

      {:ok, run_id} = Registry.start_run(registry, "tool-loop", "task")
      assert {:ok, "finished"} = attach_collect(registry, run_id)
      session_id = Registry.run_session(registry, run_id)

      {:ok, resumed} = Registry.start_run(registry, "tool-loop", "again", resume: session_id)
      assert {:ok, "finished"} = attach_collect(registry, resumed)

      # Resume is transcript continuity, not workflow replay: the inbox is
      # exactly as the runs left it.
      assert %{pending: 1, claimed: 0} = Alto.Queue.count(queue)
    end
  end

  describe "protocol surface" do
    test "start_run answers its session and sessions lists it", %{session_dir: dir} do
      parent = self()
      registry = :"sess-reg-#{System.unique_integer([:positive])}"
      start_registry(registry, [sessions: [session_dir: dir]], tool_resolver(parent))

      reply =
        wire(registry, %{
          "v" => 1,
          "type" => "start_run",
          "id" => "c-1",
          "config" => "tool-loop",
          "task" => "task"
        })

      assert %{"type" => "ok", "run_id" => run_id, "session_id" => session_id} = reply

      list = wire(registry, %{"v" => 1, "type" => "sessions", "id" => "c-2"})
      assert %{"type" => "ok", "sessions" => _} = list

      # The run may still be in flight; wait, then it must be listed.
      wait_empty(registry)
      done = wire(registry, %{"v" => 1, "type" => "sessions", "id" => "c-3"})
      assert %{"sessions" => [_ | _]} = done
      assert Enum.any?(done["sessions"], &(&1["id"] == session_id))

      # Resuming over the wire continues the same session.
      resumed =
        wire(registry, %{
          "v" => 1,
          "type" => "start_run",
          "id" => "c-4",
          "config" => "tool-loop",
          "task" => "again",
          "resume" => session_id
        })

      assert %{"type" => "ok", "session_id" => ^session_id} = resumed
      assert resumed["run_id"] != run_id
      wait_empty(registry)
    end

    test "unpersisted runs omit the session and resume reports honestly", %{
      session_dir: _dir
    } do
      parent = self()
      registry = :"sess-reg-#{System.unique_integer([:positive])}"
      start_registry(registry, [], tool_resolver(parent))

      reply =
        wire(registry, %{
          "v" => 1,
          "type" => "start_run",
          "id" => "c-1",
          "config" => "tool-loop",
          "task" => "task"
        })

      assert %{"type" => "ok", "run_id" => _} = reply
      refute Map.has_key?(reply, "session_id")

      missing =
        wire(registry, %{
          "v" => 1,
          "type" => "start_run",
          "id" => "c-2",
          "config" => "tool-loop",
          "task" => "task",
          "resume" => "sess-aaaaaaaaaaaaaaaa"
        })

      assert missing["code"] == "not_found"
      assert ["session_not_found", _] = missing["detail"]["$tuple"]

      bad_shape =
        wire(registry, %{
          "v" => 1,
          "type" => "start_run",
          "id" => "c-3",
          "config" => "tool-loop",
          "task" => "task",
          "resume" => "!!!not-a-session!!!"
        })

      assert bad_shape["code"] == "invalid"
    end
  end

  defp wire(registry, envelope) do
    Connection.run_command(JSON.encode!(envelope), registry, fn out ->
      send(self(), {:line, out})
    end)

    assert_receive {:line, out}, @receive_timeout
    JSON.decode!(IO.iodata_to_binary(out))
  end
end
