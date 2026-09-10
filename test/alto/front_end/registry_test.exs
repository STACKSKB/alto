defmodule Alto.FrontEnd.RegistryTest do
  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.FrontEnd.Registry

  @approval_timeout_ms 300
  @receive_timeout 2_000

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

  defmodule GuardedEchoTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :echo

    @impl true
    def schema, do: EchoTool.schema()

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :required

    @impl true
    def run(arguments, _context), do: EchoTool.run(arguments, nil)
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
    root = Path.join(System.tmp_dir!(), "alto-registry-#{System.unique_integer([:positive])}")
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
           approval: Alto.Approvals.DenyAll
         ]}

      "guarded-loop" ->
        {:ok,
         [
           provider: {ToolThenAnswerProvider, test_pid: parent},
           tools: [GuardedEchoTool],
           approval: Alto.Approvals.Socket,
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

  test "start_run rejects unknown configurations and invalid tasks", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)

    assert {:error, {:unknown_config, "nope"}} = Registry.start_run(registry, "nope", "task")
    assert {:error, :invalid_task} = Registry.start_run(registry, "tool-loop", "")
    assert {:error, :invalid_task} = Registry.start_run(registry, "tool-loop", :not_a_task)
  end

  test "a subscriber sees gapless durable events, live events, and one result", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry)

    assert {:ok, run_id} = Registry.start_run(registry, "tool-loop", "use the tool then answer")
    Registry.pull(registry, self(), 200)

    notifications = collect_until_result(run_id)

    events =
      Enum.flat_map(notifications, fn
        {:event, _id, seq, event} -> [{seq, event}]
        _other -> []
      end)

    assert [{:result, ^run_id, :ok, "finished", 2}] =
             Enum.filter(notifications, &match?({:result, _, _, _, _}, &1))

    seqs = events |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1)
    assert seqs == Enum.to_list(1..length(seqs))

    durable_types =
      events
      |> Enum.filter(fn {seq, _event} -> is_integer(seq) end)
      |> Enum.map(fn {_seq, event} -> event.type end)

    assert durable_types == [
             :model_completed,
             :tool_completed,
             :step_settled,
             :model_completed,
             :step_settled
           ]

    assert Enum.any?(events, fn {_seq, event} ->
             event.type == :tool_completed and event.data[:output] == ~s({"echo":"hello"})
           end)

    assert Enum.any?(events, fn {_seq, event} -> event.type == :model_started end)
    assert Registry.run_ids(registry) == []
  end

  test "domain filters keep live events away from durable-only subscribers", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry, nil, [:durable])

    {:ok, run_id} = Registry.start_run(registry, "tool-loop", "use the tool then answer")
    Registry.pull(registry, self(), 200)

    notifications = collect_until_result(run_id)

    refute Enum.any?(notifications, fn
             {:event, _id, seq, _event} -> is_nil(seq)
             _other -> false
           end)
  end

  test "an approval round-trip approves the invocation and completes the run", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root, approval_timeout: 5_000)
    attach(registry)

    {:ok, run_id} = Registry.start_run(registry, "guarded-loop", "use the tool then answer")
    Registry.pull(registry, self(), 200)

    request = wait_for_approval(run_id)

    # Approval handles are globally unique operation ids; the provider
    # call id is correlation only.
    assert request.call_id == "call-1"
    assert request.operation_id == request.id
    assert request.run_id == run_id
    assert String.starts_with?(request.id, run_id <> ":op-")
    assert request.tool == "echo"
    assert request.arguments == %{"value" => "hello"}
    assert request.execution_mode == :parallel

    assert :ok = Registry.approval_response(registry, request.id, :approve)

    assert_receive {:alto_notification, {:approval_resolved, ^run_id, ^request, :approved}},
                   @receive_timeout

    assert_receive {:alto_notification, {:event, ^run_id, _seq, %Event{type: :tool_completed}}},
                   @receive_timeout

    assert_receive {:alto_notification, {:result, ^run_id, :ok, "finished", _}}, @receive_timeout
  end

  test "a denied approval becomes a bounded tool failure", %{registry: registry, root: root} do
    start_registry(registry, root, approval_timeout: 5_000)
    attach(registry)

    {:ok, run_id} = Registry.start_run(registry, "guarded-loop", "use the tool then answer")
    Registry.pull(registry, self(), 200)

    request = wait_for_approval(run_id)
    assert :ok = Registry.approval_response(registry, request.id, {:deny, "not today"})

    assert_receive {:alto_notification,
                    {:approval_resolved, ^run_id, ^request, {:denied, "not today"}}},
                   @receive_timeout

    assert_receive {:alto_notification,
                    {:event, ^run_id, _seq, %Event{type: :tool_failed, data: %{error: error}}}},
                   @receive_timeout

    assert error == {:approval_denied, "not today"}

    assert_receive {:alto_notification, {:result, ^run_id, :ok, "finished", _}}, @receive_timeout
  end

  test "simultaneous guarded runs have independently addressable approvals", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root, approval_timeout: 5_000)
    attach(registry)

    {:ok, first_run} = Registry.start_run(registry, "guarded-loop", "first")
    {:ok, second_run} = Registry.start_run(registry, "guarded-loop", "second")
    Registry.pull(registry, self(), 200)

    approvals =
      for _ <- 1..2 do
        receive do
          {:alto_notification, {:approval_request, run_id, request}} -> {run_id, request}
        after
          @receive_timeout -> flunk("timed out waiting for approval")
        end
      end

    assert Enum.map(approvals, &elem(&1, 0)) |> Enum.sort() == Enum.sort([first_run, second_run])
    # Same provider call id in both runs, but globally unique approval handles.
    assert Enum.all?(approvals, fn {_run_id, request} -> request.call_id == "call-1" end)
    assert approvals |> Enum.map(&elem(&1, 1).id) |> Enum.uniq() |> length() == 2

    for {run_id, request} <- approvals do
      assert request.run_id == run_id
      assert request.operation_id == request.id
      assert String.starts_with?(request.id, run_id <> ":op-")
      decision = if run_id == first_run, do: :approve, else: {:deny, :second_run}
      assert :ok = Registry.approval_response(registry, request.id, decision)
    end

    assert_receive {:alto_notification, {:result, ^first_run, :ok, "finished", _}},
                   @receive_timeout

    assert_receive {:alto_notification, {:result, ^second_run, :ok, "finished", _}},
                   @receive_timeout
  end

  test "an unanswered approval fails closed under the host timeout", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry)

    {:ok, run_id} = Registry.start_run(registry, "guarded-loop", "use the tool then answer")
    Registry.pull(registry, self(), 200)

    request = wait_for_approval(run_id)

    assert_receive {:alto_notification,
                    {:event, ^run_id, _seq,
                     %Event{
                       type: :tool_failed,
                       data: %{error: {:approval_failed, {:policy_process_failed, :timeout}}}
                     }}},
                   @receive_timeout

    # The host still emits the resolved notification for the timed-out wait.
    assert_receive {:alto_notification,
                    {:approval_resolved, ^run_id, ^request,
                     {:error, {:policy_process_failed, :timeout}}}},
                   @receive_timeout

    assert_receive {:alto_notification, {:result, ^run_id, :ok, "finished", _}}, @receive_timeout

    # A decision arriving after resolution is rejected.
    assert {:error, :not_found} = Registry.approval_response(registry, request.id, :approve)
  end

  test "a run can be cancelled while another run blocks in a provider", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry)

    {:ok, blocking_id} = Registry.start_run(registry, "blocking-loop", "block forever")
    {:ok, run_id} = Registry.start_run(registry, "tool-loop", "use the tool then answer")
    Registry.pull(registry, self(), 200)

    assert :ok = Registry.cancel(registry, run_id, :operator_stop)

    assert_receive {:alto_notification,
                    {:event, ^run_id, _seq,
                     %Event{type: :run_cancelled, data: %{reason: :operator_stop}}}},
                   @receive_timeout

    assert_receive {:alto_notification, {:result, ^run_id, {:cancelled, :operator_stop}, nil, 0}},
                   @receive_timeout

    assert Registry.run_ids(registry) == [blocking_id]

    assert :ok = Registry.cancel(registry, blocking_id, :cleanup)

    wait_until(fn -> Registry.run_ids(registry) == [] end)
  end

  test "registry crash cancels its owned provider run", %{registry: registry, root: root} do
    start_registry(registry, root, sessions: [session_dir: root])
    {:ok, run_id} = Registry.start_run(registry, "blocking-loop", "block forever")
    session_id = Registry.run_session(registry, run_id)
    assert_receive {:registry_provider_started, provider_pid}, @receive_timeout
    provider_monitor = Process.monitor(provider_pid)
    old_registry = Process.whereis(registry)
    Process.exit(old_registry, :kill)

    assert_receive {:DOWN, ^provider_monitor, :process, ^provider_pid, _reason}, @receive_timeout
    wait_until(fn -> Process.whereis(registry) != old_registry end)

    wait_until(fn ->
      case Alto.Session.read(session_id, session_dir: root) do
        {:ok, records} ->
          Enum.any?(records, &(&1["type"] == "event" and &1["event"] == "run_cancelled"))

        _ ->
          false
      end
    end)
  end

  test "a finished run replays its durable log and result to a new attachment", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)

    {:ok, run_id} = Registry.start_run(registry, "tool-loop", "use the tool then answer")

    wait_until(fn -> Registry.run_ids(registry) == [] end)

    attach(registry, run_id)
    Registry.pull(registry, self(), 200)

    assert_receive {:alto_notification, {:attached, ^run_id, false, 5, replay}}, @receive_timeout

    assert Enum.map(replay, &elem(&1, 0)) == [1, 2, 3, 4, 5]

    assert Enum.map(replay, fn {_, event} -> event.type end) == [
             :model_completed,
             :tool_completed,
             :step_settled,
             :model_completed,
             :step_settled
           ]

    assert_receive {:alto_notification, {:result, ^run_id, :ok, "finished", 2}}, @receive_timeout
  end

  test "a full subscriber buffer overflows durably instead of silently dropping", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root, max_buffer_messages: 2)
    attach(registry)

    {:ok, run_id} = Registry.start_run(registry, "tool-loop", "use the tool then answer")

    wait_until(fn -> Registry.run_ids(registry) == [] end)

    Registry.pull(registry, self(), 2)

    # The two buffered notifications arrive, then queued overflow notices. A
    # durable drop records the client's last delivered seq (nil before any
    # delivery), so the client knows to resync with a fresh attach.
    assert_receive {:alto_notification, {:event, ^run_id, nil, %Event{type: :model_started}}},
                   @receive_timeout

    assert_receive {:alto_notification, {:event, ^run_id, 1, %Event{type: :model_completed}}},
                   @receive_timeout

    assert_receive {:alto_notification, {:overflow, ^run_id, :live, nil}}, @receive_timeout

    assert_receive {:alto_notification, {:overflow, ^run_id, :durable, nil}}, @receive_timeout

    # The registry stays responsive and keeps queueing for the next pull.
    Registry.pull(registry, self(), 1)
    assert_receive {:alto_notification, _next}, @receive_timeout
  end

  test "finished runs are evicted past the bounded window", %{registry: registry, root: root} do
    start_registry(registry, root, max_finished_runs: 2)

    ids =
      for _ <- 1..3 do
        {:ok, run_id} = Registry.start_run(registry, "tool-loop", "use the tool then answer")
        wait_until(fn -> Registry.run_ids(registry) == [] end)
        run_id
      end

    [first, _second, third] = ids

    assert {:error, :unknown_run} = Registry.attach(registry, self(), first, 1, [:durable])
    assert :ok = Registry.attach(registry, self(), third, 1, [:durable])
    Registry.detach(registry, self())
  end

  test "the socket approval policy denies when no registry answers", %{root: root} do
    request = %Alto.Approval.Request{
      id: "run-missing:op-1",
      run_id: "run-missing",
      call_id: "call-1",
      operation_id: "run-missing:op-1",
      tool: "echo",
      arguments: %{"value" => "hello"},
      execution_mode: :exclusive
    }

    context = %{session_id: "run-missing", cwd: root}

    assert {:deny, {:approval_unavailable, _reason}} =
             Alto.Approvals.Socket.decide(request, context, [])
  end

  test "the socket approval policy denies unaddressable requests", %{root: root} do
    request = %Alto.Approval.Request{
      id: nil,
      tool: "echo",
      arguments: %{},
      execution_mode: :exclusive
    }

    assert {:deny, :approval_request_unaddressable} =
             Alto.Approvals.Socket.decide(request, %{session_id: "run-1", cwd: root}, [])
  end

  test "a stalled subscriber has bounded data and coalesced overflow", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root, max_buffer_messages: 2, max_buffer_bytes: 512)
    :ok = Registry.attach(registry, self(), nil, 1, [:durable, :live])
    {:ok, id} = Registry.start_run(registry, "blocking-loop", "wait")

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
    assert :ok = Registry.cancel(registry, id, :cleanup)
  end

  test "retained replay returns the suffix and marks the missing prefix", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root, max_retained_events: 2)
    {:ok, id} = Registry.start_run(registry, "tool-loop", "finish")
    wait_until(fn -> Registry.run_ids(registry) == [] end)
    :ok = Registry.attach(registry, self(), id, 1, [:durable])
    Registry.pull(registry, self(), 10)
    assert_receive {:alto_notification, {:attached, ^id, true, 5, replay}}, @receive_timeout
    assert Enum.map(replay, &elem(&1, 0)) == [4, 5]
  end

  test "active runs and subscribers have admission limits", %{registry: registry, root: root} do
    start_registry(registry, root, max_active_runs: 1, max_subscribers: 0)
    assert {:error, :subscriber_capacity} = Registry.attach(registry, self(), nil, 1, [:durable])
    {:ok, id} = Registry.start_run(registry, "blocking-loop", "wait")
    assert {:error, :run_capacity} = Registry.start_run(registry, "blocking-loop", "wait")
    assert :ok = Registry.cancel(registry, id, :cleanup)
  end

  # Notifications are pull-based, so a background puller keeps the test
  # process consuming while it asserts. It stops well before the test VM.
  defp attach(registry, run_id \\ nil, domains \\ [:durable, :live])

  defp attach(registry, run_id, domains) do
    :ok = Registry.attach(registry, self(), run_id, 1, domains)
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
      {:result, ^run_id, :ok, "finished", _} -> [notification]
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

  describe "durable queue facade" do
    setup do
      dir = Path.join(System.tmp_dir!(), "alto-registry-q-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      queue = :"registry-queue-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Alto.Queue.start_link(id: "registry-facade", dir: dir, name: queue)

      %{queue: queue, dir: dir}
    end

    test "claim, ack, and release delegate to the configured queue", %{
      registry: registry,
      root: root,
      queue: queue
    } do
      start_registry(registry, root, queue: queue)

      assert {:ok, %{id: id}} = Alto.Queue.put(queue, "job-1", %{lines: 3})

      # The claim_id is only known through the facade's reply.
      assert {:ok, [claimed]} = Registry.queue_claim(registry, 1, "station-1")
      assert %{id: ^id, key: "job-1", status: :claimed, claimed_by: "station-1"} = claimed

      assert :ok = Registry.queue_release(registry, claimed.claim_id)
      assert [%{id: ^id, status: :pending}] = Alto.Queue.records(queue)

      {:ok, [reclaimed]} = Registry.queue_claim(registry, 1, "station-1")
      assert :ok = Registry.queue_ack(registry, reclaimed.claim_id)
      assert %{pending: 0, claimed: 0} = Alto.Queue.count(queue)
    end

    test "ack of a dead claim and queue-less registries fail closed", %{
      registry: registry,
      root: root,
      queue: queue
    } do
      start_registry(registry, root, queue: queue)
      assert {:error, :not_found} = Registry.queue_ack(registry, "clm-ghost")
      assert {:error, :not_found} = Registry.queue_release(registry, "clm-ghost")
    end

    test "a registry without a queue answers :no_queue", %{registry: registry, root: root} do
      start_registry(registry, root)

      assert {:error, :no_queue} = Registry.queue_claim(registry, 1, nil)
      assert {:error, :no_queue} = Registry.queue_ack(registry, "clm-1")
      assert {:error, :no_queue} = Registry.queue_release(registry, "clm-1")
    end
  end
end
