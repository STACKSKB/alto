defmodule Alto.Contrib.FrontEnd.RegistryTest do
  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.Contrib.FrontEnd.Registry
  alias Alto.Session
  alias Alto.TestSupport.EchoTool
  alias Alto.TestSupport.GuardedEchoTool
  alias Alto.TestSupport.ToolThenAnswerProvider

  @approval_timeout_ms 300
  @receive_timeout 2_000

  defmodule BlockingProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, opts) do
      if test_pid = Keyword.get(opts, :test_pid),
        do: send(test_pid, {:registry_provider_started, self()})

      receive(do: (:never -> {:ok, %{message: nil, tool_calls: []}}))
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "alto-registry-#{Base.encode16(:crypto.strong_rand_bytes(8))}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    registry = :"registry-#{System.unique_integer([:positive])}"
    %{registry: registry, root: root}
  end

  defp start_registry(registry, root, overrides \\ []) do
    parent = self()

    # The fail-closed timeout path is pinned with a tight bound, but the
    # approve/deny round-trips answer as fast as the scheduler allows — under
    # parallel load that can exceed a tight bound through no fault of the
    # product, so round-trip tests opt into a generous timeout.
    {approval_timeout, overrides} =
      Keyword.pop(overrides, :approval_timeout, @approval_timeout_ms)

    resolver = fn
      "tool-loop" ->
        {:ok,
         [
           provider: {ToolThenAnswerProvider, test_pid: parent},
           tools: [EchoTool],
           approval: {:deny, :policy_denied}
         ]}

      "guarded-loop" ->
        {:ok,
         [
           provider: {ToolThenAnswerProvider, test_pid: parent},
           tools: [GuardedEchoTool],
           approval: &Alto.Contrib.Approval.socket/2,
           approval_timeout: approval_timeout
         ]}

      "blocking-loop" ->
        {:ok, [provider: {BlockingProvider, test_pid: parent}, tools: [], max_steps: 1]}

      other ->
        {:error, {:unknown_config, other}}
    end

    opts = Keyword.merge([name: registry, config_resolver: resolver, cwd: root], overrides)

    start_supervised!({Registry, opts})
    registry
  end

  test "session_transcript keeps only the latest 100 messages", %{registry: registry, root: root} do
    start_registry(registry, root, session_dir: root)
    {:ok, session_id} = Session.create("prompt", %{}, session_dir: root)
    messages = Enum.map(1..101, &%{"role" => "user", "content" => Integer.to_string(&1)})
    {:ok, _snapshot} = Session.persist_settled(session_id, messages, 0, session_dir: root)

    assert {:ok, %{messages: page, truncated: true}} =
             Registry.request(registry, {:session_transcript, session_id})

    assert length(page) == 100
    assert hd(page)["content"] == "2"
    assert List.last(page)["content"] == "101"
  end

  test "domain filters keep live events away from durable-only subscribers", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry, nil, [:durable])

    {:ok, run_id} =
      Registry.request(registry, {:start_run, "tool-loop", "use the tool then answer", []})

    Registry.pull(registry, self(), 200)

    notifications = collect_until_result(run_id)

    refute Enum.any?(notifications, fn
             {:event, _id, seq, _event} -> is_nil(seq)
             _other -> false
           end)
  end

  test "an unanswered approval fails closed under the host timeout", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry)

    {:ok, run_id} =
      Registry.request(registry, {:start_run, "guarded-loop", "use the tool then answer", []})

    Registry.pull(registry, self(), 200)

    request = wait_for_approval(run_id)

    assert_receive {:alto_notification,
                    {:event, ^run_id, _seq,
                     %Event{
                       type: :tool_failed,
                       data: %{error: {:approval_failed, {:participant_failed, :timeout}}}
                     }}},
                   @receive_timeout

    # The host still emits the resolved notification for the timed-out wait.
    assert_receive {:alto_notification,
                    {:approval_resolved, ^run_id, ^request,
                     {:error, {:participant_failed, :timeout}}}},
                   @receive_timeout

    assert_receive {:alto_notification,
                    {:result, ^run_id, %{status: :ok, output: "finished", model_requests: _}}},
                   @receive_timeout

    # A decision arriving after resolution is rejected.
    assert {:error, :not_found} =
             Registry.request(registry, {:approval_response, request.id, :approve})
  end

  test "a run can be cancelled while another run blocks in a provider", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry)

    {:ok, blocking_id} =
      Registry.request(registry, {:start_run, "blocking-loop", "block forever", []})

    {:ok, run_id} =
      Registry.request(registry, {:start_run, "tool-loop", "use the tool then answer", []})

    Registry.pull(registry, self(), 200)

    assert :ok = Registry.request(registry, {:cancel, run_id, :operator_stop})

    assert_receive {:alto_notification,
                    {:event, ^run_id, _seq,
                     %Event{type: :run_cancelled, data: %{reason: :operator_stop}}}},
                   @receive_timeout

    assert_receive {:alto_notification,
                    {:result, ^run_id,
                     %{status: :cancelled, reason: :operator_stop, output: nil, model_requests: 0}}},
                   @receive_timeout

    assert Registry.request(registry, :run_ids) == [blocking_id]

    assert :ok = Registry.request(registry, {:cancel, blocking_id, :cleanup})

    wait_until(fn -> Registry.request(registry, :run_ids) == [] end)
  end

  test "registry crash cancels its owned provider run", %{registry: registry, root: root} do
    start_registry(registry, root, sessions: [session_dir: root])
    {:ok, run_id} = Registry.request(registry, {:start_run, "blocking-loop", "block forever", []})
    session_id = Registry.request(registry, {:run_session, run_id})
    assert_receive {:registry_provider_started, provider_pid}, @receive_timeout
    provider_monitor = Process.monitor(provider_pid)
    old_registry = Process.whereis(registry)
    run_pid = Alto.Test.Runner.worker(:sys.get_state(registry).runs[run_id].handle)
    run_monitor = Process.monitor(run_pid)
    Process.exit(old_registry, :kill)

    assert_receive {:DOWN, ^provider_monitor, :process, ^provider_pid, _reason}, @receive_timeout
    wait_until(fn -> Process.whereis(registry) != old_registry end)

    wait_until(fn ->
      case Alto.Session.read(session_id, session_dir: root) do
        {:ok, records} ->
          Enum.any?(records, &(&1["type"] == "event" and &1["event"] == "run_cancelled")) and
            Enum.any?(records, &(&1["type"] == "completed"))

        _ ->
          false
      end
    end)

    assert_receive {:DOWN, ^run_monitor, :process, ^run_pid, _reason}, @receive_timeout
    stop_supervised!(Registry)
  end

  test "a full subscriber buffer overflows durably instead of silently dropping", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root, max_buffer_messages: 2)
    # This scenario must not use the background-pulling helper: the buffer
    # needs to remain full until the explicit pull below.
    :ok = Registry.request(registry, {:attach, self(), nil, 1, [:durable, :live]})

    {:ok, run_id} =
      Registry.request(registry, {:start_run, "tool-loop", "use the tool then answer", []})

    wait_until(fn -> Registry.request(registry, :run_ids) == [] end)

    Registry.pull(registry, self(), 2)

    # The two buffered notifications arrive, then queued overflow notices. A
    # durable drop records the client's last delivered seq (nil before any
    # delivery), so the client knows to resync with a fresh attach.
    assert_receive {:alto_notification, {:event, ^run_id, nil, %Event{type: :model_started}}},
                   @receive_timeout

    assert_receive {:alto_notification, {:event, ^run_id, 1, %Event{type: :model_completed}}},
                   @receive_timeout

    assert_receive {:alto_notification, {:overflow, nil, :live, nil}}, @receive_timeout

    assert_receive {:alto_notification, {:overflow, ^run_id, :durable, nil}}, @receive_timeout

    # Overflow reporting leaves the resident responsive.
    assert Registry.request(registry, :run_ids) == []
  end

  test "finished runs are evicted past the bounded window", %{registry: registry, root: root} do
    start_registry(registry, root, max_finished_runs: 2)

    ids =
      for _ <- 1..3 do
        {:ok, run_id} =
          Registry.request(registry, {:start_run, "tool-loop", "use the tool then answer", []})

        wait_until(fn -> Registry.request(registry, :run_ids) == [] end)
        run_id
      end

    [first, _second, third] = ids

    assert {:error, :unknown_run} =
             Registry.request(registry, {:attach, self(), first, 1, [:durable]})

    assert :ok = Registry.request(registry, {:attach, self(), third, 1, [:durable]})
    Registry.request(registry, {:detach, self()})
  end

  test "the socket approval policy denies when no registry answers", %{root: root} do
    request = %{
      id: "run-missing:op-1",
      run_id: "run-missing",
      call_id: "call-1",
      tool: "echo",
      arguments: %{"value" => "hello"},
      execution_mode: :exclusive,
      details: %{}
    }

    context = %{session_id: "run-missing", cwd: root}

    assert {:deny, {:approval_unavailable, _reason}} =
             Alto.Contrib.Approval.socket(request, context)
  end

  test "the socket approval policy denies unaddressable requests", %{root: root} do
    request = %{
      id: nil,
      run_id: nil,
      call_id: nil,
      tool: "echo",
      arguments: %{},
      execution_mode: :exclusive,
      details: %{}
    }

    assert {:deny, :approval_request_unaddressable} =
             Alto.Contrib.Approval.socket(request, %{session_id: "run-1", cwd: root})
  end

  test "a stalled subscriber has bounded data and coalesced overflow", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root, max_buffer_messages: 2, max_buffer_bytes: 512)
    :ok = Registry.request(registry, {:attach, self(), nil, 1, [:durable, :live]})
    {:ok, id} = Registry.request(registry, {:start_run, "blocking-loop", "wait", []})

    for n <- 1..1_000 do
      :ok =
        GenServer.call(
          registry,
          {:ingest_run_event, id,
           Event.live(:progress, %{n: n, text: String.duplicate("x", 1_000)})}
        )
    end

    sub = :sys.get_state(registry).subscribers[self()]
    assert sub.buffered_count <= 2
    assert sub.buffered_bytes <= 512
    assert length(sub.overflow) <= 2
    assert :ok = Registry.request(registry, {:cancel, id, :cleanup})
  end

  test "retained replay returns the suffix and marks the missing prefix", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root, max_retained_events: 2)
    {:ok, id} = Registry.request(registry, {:start_run, "tool-loop", "finish", []})
    wait_until(fn -> Registry.request(registry, :run_ids) == [] end)
    :ok = Registry.request(registry, {:attach, self(), id, 1, [:durable]})
    Registry.pull(registry, self(), 10)
    assert_receive {:alto_notification, {:attached, ^id, true, 5, replay}}, @receive_timeout
    assert Enum.map(replay, &elem(&1, 0)) == [4, 5]
  end

  test "active runs and subscribers have admission limits", %{registry: registry, root: root} do
    start_registry(registry, root, max_active_runs: 1, max_subscribers: 0)

    assert {:error, :subscriber_capacity} =
             Registry.request(registry, {:attach, self(), nil, 1, [:durable]})

    {:ok, id} = Registry.request(registry, {:start_run, "blocking-loop", "wait", []})

    assert {:error, :run_capacity} =
             Registry.request(registry, {:start_run, "blocking-loop", "wait", []})

    assert :ok = Registry.request(registry, {:cancel, id, :cleanup})
  end

  test "zero replay-byte budget reports a gap without dropping terminal delivery", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root, max_retained_event_bytes: 0)
    {:ok, id} = Registry.request(registry, {:start_run, "tool-loop", "finish", []})
    wait_until(fn -> Registry.request(registry, :run_ids) == [] end)
    :ok = Registry.request(registry, {:attach, self(), id, 1, [:durable]})
    Registry.pull(registry, self(), 10)
    assert_receive {:alto_notification, {:attached, ^id, true, 5, []}}, @receive_timeout
    assert_receive {:alto_notification, {:result, ^id, _}}, @receive_timeout
  end

  test "finished-byte eviction still publishes the result and releases its host", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root, max_finished_bytes: 0)
    :ok = Registry.request(registry, {:attach, self(), nil, 1, [:durable]})
    {:ok, id} = Registry.request(registry, {:start_run, "blocking-loop", "wait", []})
    run = :sys.get_state(registry).runs[id]
    host = run.handle.state.pid
    monitor = Process.monitor(host)
    assert :ok = Registry.request(registry, {:cancel, id, :cleanup})
    wait_until(fn -> Registry.request(registry, :run_ids) == [] end)
    assert_receive {:DOWN, ^monitor, :process, ^host, :normal}, @receive_timeout
    Registry.pull(registry, self(), 100)
    assert_receive {:alto_notification, {:result, ^id, _}}, @receive_timeout
  end

  test "subscriber bytes are bounded across all clients", %{registry: registry, root: root} do
    start_registry(registry, root, max_subscriber_bytes: 256)

    peer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(peer, :stop) end)

    for client <- [self(), peer],
        do: :ok = Registry.request(registry, {:attach, client, nil, 1, [:durable]})

    {:ok, _} = Registry.request(registry, {:start_run, "tool-loop", "finish", []})
    wait_until(fn -> Registry.request(registry, :run_ids) == [] end)
    subs = :sys.get_state(registry).subscribers |> Map.values()
    assert Enum.sum(Enum.map(subs, & &1.buffered_bytes)) <= 256
    assert Enum.any?(subs, &(&1.overflow != []))
  end

  # Notifications are pull-based, so a background puller keeps the test
  # process consuming while it asserts. It stops well before the test VM.
  defp attach(registry, run_id \\ nil, domains \\ [:durable, :live])

  defp attach(registry, run_id, domains) do
    :ok = Registry.request(registry, {:attach, self(), run_id, 1, domains})
    client = self()
    deadline = System.monotonic_time(:millisecond) + 120_000

    spawn(fn ->
      puller_loop(registry, client, deadline)
    end)

    :ok
  end

  defp puller_loop(registry, client_pid, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Registry.pull(registry, client_pid, 100)
      Process.sleep(5)
      puller_loop(registry, client_pid, deadline)
    end
  end

  defp collect_until_result(run_id) do
    assert_receive {:alto_notification, notification}, @receive_timeout

    case notification do
      {:result, ^run_id, %{status: :ok, output: "finished", model_requests: _}} -> [notification]
      other -> [other | collect_until_result(run_id)]
    end
  end

  defp wait_for_approval(run_id) do
    assert_receive {:alto_notification, notification}, @receive_timeout

    case notification do
      {:approval_request, ^run_id, request} -> request
      _other -> wait_for_approval(run_id)
    end
  end

  defp wait_until(fun, attempts \\ 300)

  defp wait_until(_fun, 0), do: flunk("condition not met within timeout")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
