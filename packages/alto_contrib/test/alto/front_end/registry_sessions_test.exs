defmodule Alto.Contrib.FrontEnd.RegistrySessionsTest do
  @moduledoc """
  : explicit served-agent session persistence and resume.

  Registry-started runs persist (transcript continuity + audit facts) only
  when the operator opts in; resume reuses the named session verbatim.
  Inbox ownership stays in the queue and operation recovery in the ledger —
  resume touches neither. A saved transcript is continuity, not workflow
  replay: crashed runs report their state instead of rerunning effects.
  """

  use ExUnit.Case, async: true

  alias Alto.Contrib.FrontEnd.Registry
  alias Alto.TestSupport.ToolThenAnswerProvider

  @receive_timeout 5_000

  defmodule EchoTool do
    use Alto.Tool, name: :echo, execution_mode: :parallel, approval: :never
    @impl true
    def schema(_opts) do
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
    def run(%{"value" => value}, _context, opts) do
      if pid = Keyword.get(opts, :test_pid), do: send(pid, {:tool_ran, value})
      {:ok, %{echo: value}}
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

  defmodule SpawnBlockerLoop do
    @moduledoc false
    # Delegates to a blocking child; the binary task is opaque so the loop
    # works over the string-task registry boundary.
    @behaviour Alto.Loop
    @impl true
    def init(_task, _spec) do
      {:continue, %{},
       [
         {:spawn_agents,
          %{
            agents: [
              %{
                id: "sub-1",
                task: "child",
                profile_key: "blocking"
              }
            ]
          }}
       ]}
    end

    @impl true
    def handle_event(
          %Alto.Event{type: :subagents_completed, data: %{results: [%{status: :error} = data]}},
          s,
          _spec
        ),
        do: {{:stop, {:failed, data}}, s, []}

    def handle_event(%Alto.Event{type: :subagents_completed, data: %{results: [data]}}, s, _spec),
      do: {{:stop, {:completed, data}}, s, []}

    def handle_event(_event, state, _spec), do: {:continue, state, []}

    @impl true
    def resolve_child_provider("blocking", spec) do
      {:ok, {BlockingProvider, test_pid: Keyword.fetch!(spec.driver_options, :test_pid)}}
    end

    def resolve_child_provider(_, _), do: {:error, :unknown_profile}
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
           approval: {:deny, :policy_denied}
         ]}

      other ->
        {:error, {:unknown_config, other}}
    end
  end

  defp counting_tool_resolver(parent) do
    fn
      "tool-loop" ->
        {:ok,
         [
           provider: {ToolThenAnswerProvider, test_pid: parent},
           tools: [{EchoTool, test_pid: parent}],
           approval: :approve
         ]}

      other ->
        {:error, {:unknown_config, other}}
    end
  end

  defp wait_empty(registry) do
    wait_until(fn -> Registry.request(registry, :run_ids) == [] end)
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
    :ok = Registry.request(registry, {:attach, self(), run_id, 1, [:durable, :live]})
    client = self()
    puller = spawn(fn -> pull_loop(registry, client) end)
    result = collect_until_result(run_id)
    Process.exit(puller, :kill)
    Registry.request(registry, {:detach, self()})
    result
  end

  defp pull_loop(registry, client) do
    Registry.pull(registry, client, 100)
    Process.sleep(5)
    pull_loop(registry, client)
  end

  defp collect_until_result(run_id) do
    receive do
      {:alto_notification, {:result, ^run_id, result}} -> result
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

  describe "crash honesty" do
    test "a killed run reports no resumable transcript and never reruns", %{session_dir: dir} do
      parent = self()
      registry = :"sess-reg-#{System.unique_integer([:positive])}"

      resolver = counting_tool_resolver(parent)

      start_registry(registry, [sessions: [session_dir: dir]], resolver)

      {:ok, run_id} = Registry.request(registry, {:start_run, "tool-loop", "doomed task", []})
      assert_receive {:tool_ran, "hello"}, @receive_timeout

      # Crash the run mid-flight: no snapshot, no completed record.
      %{handle: handle} = :sys.get_state(registry).runs[run_id]
      pid = Alto.Test.Runner.worker(handle)
      Process.exit(pid, :kill)
      wait_empty(registry)

      # Drain everything the dead run emitted; from here it is silent.
      _ = drain(:tool_ran)
      _ = drain(:provider_request)

      session_id = Registry.request(registry, {:run_session, run_id})
      assert is_binary(session_id)

      # The actual recoverable state: audit facts exist, nothing resumable.
      assert {:ok, records} = Alto.Session.read(session_id, session_dir: dir)
      assert Enum.any?(records, &(&1["type"] == "started"))
      refute Enum.any?(records, &(&1["type"] == "completed"))

      assert {:error, :no_resumable_transcript} =
               Alto.Session.transcript(session_id, session_dir: dir)

      assert {:error, :no_resumable_transcript} =
               Registry.request(
                 registry,
                 {:start_run, "tool-loop", "retry", [resume: session_id]}
               )

      # Nothing reran after the failed resume.
      assert drain(:tool_ran) == []
      assert drain(:provider_request) == []

      assert {:ok, [summary]} = Registry.request(registry, :sessions)
      assert summary.completed_runs == 0
      assert summary.last_status == nil
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
             approval: {:deny, :policy_denied}
           ]}

        other ->
          {:error, {:unknown_config, other}}
      end

      start_registry(registry, [sessions: [session_dir: dir]], resolver)

      {:ok, run_id} =
        Registry.request(registry, {:start_run, "spawn-loop", "delegate and block", []})

      assert_receive :child_entered, @receive_timeout

      assert :ok = Registry.request(registry, {:cancel, run_id, :operator_stop})
      wait_empty(registry)

      session_id = Registry.request(registry, {:run_session, run_id})

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

      assert child_completed["status"] == "cancelled"

      # Root snapshot ownership: the transcript holds only the root run's
      # single user message — the child never overwrote it.
      assert {:ok, %{"messages" => [single]}} =
               Alto.Session.transcript(session_id, session_dir: dir)

      assert single["role"] == "user"
    end
  end

  describe "eviction, storage, and secrets" do
    test "persisted records carry no credentials", %{session_dir: dir} do
      registry = :"sess-reg-#{System.unique_integer([:positive])}"

      resolver = fn
        "secret-loop" ->
          {:ok,
           [
             provider: {SecretProvider, api_key: "sk-test-SECRET-xyz", model: "m"},
             tools: [],
             approval: {:deny, :policy_denied}
           ]}

        other ->
          {:error, {:unknown_config, other}}
      end

      start_registry(registry, [sessions: [session_dir: dir]], resolver)

      {:ok, run_id} = Registry.request(registry, {:start_run, "secret-loop", "harmless task", []})
      assert %{status: :ok, output: "done"} = attach_collect(registry, run_id)

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

      {:ok, _} = Alto.Queue.request(queue, {:admit, "src:del-1", %{"body" => "x"}, []})
      assert %{pending: 1} = Alto.Queue.request(queue, :count)

      {:ok, run_id} = Registry.request(registry, {:start_run, "tool-loop", "task", []})
      assert %{status: :ok, output: "finished"} = attach_collect(registry, run_id)
      session_id = Registry.request(registry, {:run_session, run_id})

      {:ok, resumed} =
        Registry.request(registry, {:start_run, "tool-loop", "again", [resume: session_id]})

      assert %{status: :ok, output: "finished"} = attach_collect(registry, resumed)

      # Resume is transcript continuity, not workflow replay: the inbox is
      # exactly as the runs left it.
      assert %{pending: 1, claimed: 0} = Alto.Queue.request(queue, :count)
    end
  end
end
