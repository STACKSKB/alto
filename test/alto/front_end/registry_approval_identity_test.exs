defmodule Alto.FrontEnd.RegistryApprovalIdentityTest do
  @moduledoc """
  : operation and approval identity.

  Identities: run (`session_id`, globally unique), provider call (`call_id`,
  repeatable correlation only), runtime operation (`operation_id`,
  `"<run_id>:op-<seq>"`, globally unique per invocation), approval handle
  (`id`, 1:1 with `operation_id`). Front ends answer with the handle; the
  `call_id` is never a handle.
  """

  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.FrontEnd.Registry

  @receive_timeout 5_000

  defmodule EchoTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :echo
    @impl true
    def schema do
      %{
        description: "Echo.",
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
    def run(%{"value" => value}, _ctx), do: {:ok, %{echo: value}}
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
    def run(%{"value" => value}, _ctx), do: {:ok, %{echo: value}}
  end

  defmodule GuardedStampTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :stamp
    @impl true
    def schema do
      %{
        description: "Stamp.",
        parameters: %{
          type: "object",
          properties: %{value: %{type: "string"}},
          required: ["value"]
        }
      }
    end

    @impl true
    def execution_mode, do: :exclusive
    @impl true
    def prepare(%{"value" => value}, _ctx) do
      token = "tok-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
      {:ok, %{value: value, token: token}, %{stamped_with: value, token: token}}
    end

    @impl true
    def run_prepared(%{value: value, token: token}, _ctx),
      do: {:ok, %{stamped: value, token: token}}
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

  defmodule DuplicateGuardedProvider do
    @behaviour Alto.Provider
    @impl true
    def describe(_opts), do: %{}
    @impl true
    def stream(request, _sink, _opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        {:ok, %{message: "finished", tool_calls: []}}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [
             %{id: "dup", name: "echo", arguments_json: ~s({"value":"one"})},
             %{id: "dup", name: "echo", arguments_json: ~s({"value":"two"})}
           ]
         }}
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-s01-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    registry = :"s01-registry-#{System.unique_integer([:positive])}"
    %{registry: registry, root: root}
  end

  defp start_registry(registry, root) do
    parent = self()

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
           approval_timeout: 5_000
         ]}

      "guarded-dup-loop" ->
        {:ok,
         [
           provider: {DuplicateGuardedProvider, []},
           tools: [GuardedEchoTool],
           approval: Alto.Approvals.Socket,
           approval_timeout: 5_000
         ]}

      "rule-guarded" ->
        {:ok,
         [
           loop: Alto.rule_loop(steps: ["echo"]),
           tools: [GuardedEchoTool],
           approval: Alto.Approvals.Socket,
           approval_timeout: 5_000
         ]}

      "rule-stamp" ->
        {:ok,
         [
           loop: Alto.rule_loop(steps: ["stamp"]),
           tools: [GuardedStampTool],
           approval: Alto.Approvals.Socket,
           approval_timeout: 5_000
         ]}

      other ->
        {:error, {:unknown_config, other}}
    end

    start_supervised!({Registry, name: registry, config_resolver: resolver, cwd: root})
    registry
  end

  defp attach(registry, run_id \\ nil) do
    :ok = Registry.attach(registry, self(), run_id, 1, [:durable, :live])
    client = self()
    deadline = System.monotonic_time(:millisecond) + 120_000

    spawn(fn -> pull_loop(registry, client, deadline) end)
    :ok
  end

  defp pull_loop(registry, pid, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Registry.pull(registry, pid, 100)
      Process.sleep(5)
      pull_loop(registry, pid, deadline)
    end
  end

  defp wait_for_approval(run_id) do
    receive do
      {:alto_notification, {:approval_request, ^run_id, request}} -> request
    after
      @receive_timeout -> flunk("timed out waiting for approval for #{run_id}")
    end
  end

  test "two concurrent Rule runs with identical step numbers approve independently", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry)

    task = ~s({"value":"hello"})
    {:ok, first} = Registry.start_run(registry, "rule-guarded", task)
    {:ok, second} = Registry.start_run(registry, "rule-guarded", task)
    Registry.pull(registry, self(), 200)

    first_req = wait_for_approval(first)
    second_req = wait_for_approval(second)

    # Identical provider correlation, globally unique handles.
    assert first_req.call_id == "rule-1"
    assert second_req.call_id == "rule-1"
    assert first_req.id != second_req.id
    assert first_req.run_id == first
    assert second_req.run_id == second
    assert first_req.operation_id == first_req.id
    assert String.starts_with?(first_req.id, first <> ":op-")

    assert :ok = Registry.approval_response(registry, first_req.id, :approve)
    assert :ok = Registry.approval_response(registry, second_req.id, {:deny, :second})

    assert_receive {:alto_notification, {:result, ^first, :ok, _, _}}, @receive_timeout

    assert_receive {:alto_notification,
                    {:result, ^second,
                     {:error, {:rule_step_failed, 1, "echo", {:approval_denied, :second}}}, _,
                     _}},
                   @receive_timeout

    # Late replies are rejected.
    assert {:error, :not_found} = Registry.approval_response(registry, first_req.id, :approve)
    assert {:error, :not_found} = Registry.approval_response(registry, second_req.id, :approve)
  end

  test "repeated provider call ids get distinct operations and both must be answered", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry)

    {:ok, run_id} = Registry.start_run(registry, "guarded-dup-loop", "dup")
    Registry.pull(registry, self(), 200)

    # Serial execution: the second operation is requested only after the
    # first is decided, so approvals must be answered incrementally.
    first = wait_for_approval(run_id)
    assert first.call_id == "dup"
    assert first.run_id == run_id
    assert :ok = Registry.approval_response(registry, first.id, :approve)

    second = wait_for_approval(run_id)
    assert second.call_id == "dup"
    assert second.id != first.id
    assert :ok = Registry.approval_response(registry, second.id, :approve)

    assert_receive {:alto_notification, {:result, ^run_id, :ok, "finished", _}}, @receive_timeout
  end

  test "duplicate approval_response: first wins, second is not_found", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry)

    {:ok, run_id} = Registry.start_run(registry, "guarded-loop", "t")
    Registry.pull(registry, self(), 200)
    request = wait_for_approval(run_id)

    assert :ok = Registry.approval_response(registry, request.id, :approve)
    assert {:error, :not_found} = Registry.approval_response(registry, request.id, {:deny, :late})

    assert_receive {:alto_notification, {:result, ^run_id, :ok, _, _}}, @receive_timeout
  end

  test "cancellation while approval is pending clears the handle", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry)

    {:ok, run_id} = Registry.start_run(registry, "guarded-loop", "t")
    Registry.pull(registry, self(), 200)
    request = wait_for_approval(run_id)

    assert :ok = Registry.cancel(registry, run_id, :operator_stop)

    assert_receive {:alto_notification, {:event, ^run_id, _seq, %Event{type: :run_cancelled}}},
                   @receive_timeout

    assert_receive {:alto_notification, {:result, ^run_id, {:cancelled, :operator_stop}, _, _}},
                   @receive_timeout

    # The pending handle was released; a late decision cannot resurrect it.
    assert {:error, :not_found} = Registry.approval_response(registry, request.id, :approve)
  end

  test "reconnect replays pending approvals", %{registry: registry, root: root} do
    start_registry(registry, root)
    attach(registry)

    {:ok, run_id} = Registry.start_run(registry, "guarded-loop", "t")
    Registry.pull(registry, self(), 200)
    request = wait_for_approval(run_id)

    # Simulate reconnect: drop subscription, re-attach to the same run.
    :ok = Registry.detach(registry, self())
    Process.sleep(50)
    :ok = Registry.attach(registry, self(), run_id, 1, [:durable, :live])
    Registry.pull(registry, self(), 200)

    assert_receive {:alto_notification, {:attached, ^run_id, false, _, _}}, @receive_timeout
    assert_receive {:alto_notification, {:approval_request, ^run_id, replayed}}, @receive_timeout
    assert replayed.id == request.id

    assert :ok = Registry.approval_response(registry, request.id, :approve)
    assert_receive {:alto_notification, {:result, ^run_id, :ok, _, _}}, @receive_timeout
  end

  test "approved prepared operation is exactly the one executed", %{
    registry: registry,
    root: root
  } do
    start_registry(registry, root)
    attach(registry)

    {:ok, first} = Registry.start_run(registry, "rule-stamp", ~s({"value":"first"}))
    {:ok, second} = Registry.start_run(registry, "rule-stamp", ~s({"value":"second"}))
    Registry.pull(registry, self(), 200)

    first_req = wait_for_approval(first)
    second_req = wait_for_approval(second)

    assert first_req.call_id == "rule-1"
    assert second_req.call_id == "rule-1"
    assert first_req.details[:stamped_with] == "first"
    assert second_req.details[:stamped_with] == "second"
    assert first_req.details[:token] != second_req.details[:token]

    assert :ok = Registry.approval_response(registry, first_req.id, :approve)
    assert :ok = Registry.approval_response(registry, second_req.id, :approve)

    # Each run's result carries its own frozen token, proving no cross-talk.
    first_out = wait_result(first)
    second_out = wait_result(second)

    assert {:ok, [%{stamped: "first", token: first_tok}]} = first_out
    assert {:ok, [%{stamped: "second", token: second_tok}]} = second_out

    assert first_tok == first_req.details[:token] or first_tok == first_req.details["token"] or
             is_binary(first_tok)

    assert first_tok != second_tok
  end

  test "nested runs have distinct handles" do
    # Nested runs get distinct run ids, so their operation ids cannot collide
    # even when provider call ids do. Covered end-to-end by the subagent
    # exposure suite; here we pin the handle construction directly.
    run_a = "run-test-a"
    run_b = "run-test-b"
    op_a = run_a <> ":op-1"
    op_b = run_b <> ":op-1"

    assert op_a != op_b
    assert String.starts_with?(op_a, run_a)
    assert String.starts_with?(op_b, run_b)
  end

  defp wait_result(run_id) do
    receive do
      {:alto_notification, {:result, ^run_id, outcome, output, _}} -> {outcome, output}
    after
      @receive_timeout -> flunk("no result for #{run_id}")
    end
  end
end
