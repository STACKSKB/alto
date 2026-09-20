defmodule Alto.Runner.ConformanceTest do
  use ExUnit.Case, async: true

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Transition

  defmodule PreparedTool do
    @behaviour Alto.Tool

    @impl true
    def name(_opts), do: :prepared

    @impl true
    def schema(_opts) do
      %{description: "A conformance tool.", parameters: %{type: "object", properties: %{}}}
    end

    @impl true
    def execution_mode(_opts), do: :exclusive

    @impl true
    def approval(_opts), do: :required

    @impl true
    def prepare(_arguments, _context, _opts), do: {:ok, %{value: "prepared"}, %{display: "safe"}}

    @impl true
    def run_prepared(prepared, context, _opts) do
      send(context.metadata[:test_pid], {:prepared_ran, prepared.value})
      {:ok, prepared.value}
    end
  end

  defmodule NativeLoop do
    @behaviour Alto.Loop

    @impl true
    def init(_task, _spec) do
      Transition.continue(%{}, [
        Effect.invoke_tool(%{id: "native-1", name: "prepared", arguments: %{}})
      ])
    end

    @impl true
    def handle_event(%Event{type: :tool_completed, data: data}, state, _spec),
      do: Transition.stop(state, Map.get(data, :value, Map.get(data, :output)))

    def handle_event(%Event{type: :tool_failed, data: %{error: error}}, state, _spec),
      do: Transition.stop(state, {:failed, error})

    def handle_event(_event, state, _spec), do: Transition.continue(state)

    @impl true
    def dump_checkpoint(state, _spec), do: {:ok, state}

    @impl true
    def load_checkpoint(checkpoint, _spec), do: {:ok, checkpoint}
  end

  defmodule AnswerProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), :provider_called)

      {:ok,
       %{
         message: Keyword.get(opts, :answer, "answer"),
         tool_calls: [],
         usage: %{input_tokens: 3, output_tokens: 2}
       }}
    end
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_started, self()})

      receive do
        :never -> {:ok, %{message: "unreachable", tool_calls: []}}
      end
    end
  end

  defmodule SpawnLoop do
    @behaviour Alto.Loop

    @impl true
    def init(_task, _spec) do
      Transition.continue(%{}, [
        Effect.spawn_agents(%{
          agents: [%{id: "child", task: "child", loop: Alto.chat_loop()}]
        })
      ])
    end

    @impl true
    def handle_event(
          %Event{type: :subagents_completed, data: %{results: [%{status: :error} = data]}},
          state,
          _spec
        ),
        do: Transition.stop(state, {:failed, data})

    def handle_event(%Event{type: :subagents_completed, data: %{results: [data]}}, state, _spec),
      do: Transition.stop(state, {:completed, data})

    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  defmodule RegistryTool do
    @behaviour Alto.Tool

    @impl true
    def name(_opts), do: :registry_echo

    @impl true
    def schema(_opts),
      do: %{description: "Registry tool.", parameters: %{type: "object", properties: %{}}}

    @impl true
    def execution_mode(_opts), do: :parallel

    @impl true
    def approval(_opts), do: :never

    @impl true
    def run(_arguments, context, _opts) do
      if pid = context.metadata[:test_pid], do: send(pid, {:tool_ran, :registry})
      {:ok, :registry_ok}
    end
  end

  defmodule RegistryLoop do
    @behaviour Alto.Loop

    @impl true
    def init(_task, _spec),
      do: Transition.continue(%{}, [Effect.invoke_tool(%{name: "registry_echo", arguments: %{}})])

    @impl true
    def handle_event(%Event{type: :tool_completed, data: data}, state, _spec),
      do: Transition.stop(state, Map.get(data, :value, Map.get(data, :output)))

    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  defp base_opts(runner, extra) do
    Keyword.merge(
      [
        runner: runner,
        provider: nil,
        tool_context_metadata: %{test_pid: self()},
        max_steps: 8
      ],
      extra
    )
  end

  test "native prepared tool approval is shared by Serial" do
    runner = Alto.Runner.Serial

    assert {:ok, result} =
             Alto.run(
               %{},
               base_opts(runner,
                 loop: Alto.loop(NativeLoop),
                 tools: [PreparedTool],
                 approval: Alto.Approvals.AllowAll
               )
             )

    assert result.output == "prepared"
    assert_receive {:prepared_ran, "prepared"}

    assert {:ok, denied} =
             Alto.run(
               %{},
               base_opts(runner,
                 loop: Alto.loop(NativeLoop),
                 tools: [PreparedTool],
                 approval: Alto.Approvals.DenyAll
               )
             )

    assert {:failed, {:approval_denied, :policy_denied}} = denied.output
    refute_receive {:prepared_ran, _}
  end

  test "provider completion and normalized usage are shared by Serial" do
    runner = Alto.Runner.Serial

    assert {:ok, result} =
             Alto.run(
               "hello",
               base_opts(runner,
                 loop: Alto.chat_loop(),
                 provider: {AnswerProvider, test_pid: self(), answer: "answer"}
               )
             )

    assert result.output == "answer"
    assert result.usage.input_tokens == 3
    assert result.usage.output_tokens == 2
    assert result.usage.requests == 1
    assert_receive :provider_called
  end

  test "cancellation while a provider is running is exposed through the Serial runner handle" do
    runner = Alto.Runner.Serial

    assert {:ok, handle} =
             Alto.start(
               "wait",
               base_opts(runner,
                 loop: Alto.chat_loop(),
                 provider: {BlockingProvider, test_pid: self()},
                 provider_timeout: 5_000,
                 run_timeout: 5_000
               )
             )

    assert_receive {:provider_started, _pid}, 2_000
    assert :ok = Alto.cancel(handle, :conformance_cancel)
    assert {:error, {:cancelled, :conformance_cancel}, _result} = Alto.await(handle, 2_000)
  end

  test "checkpoint suspension and resume preserve the shared prepared continuation" do
    runner = Alto.Runner.Serial

    opts =
      base_opts(runner,
        loop: Alto.loop(NativeLoop),
        tools: [PreparedTool],
        approval: Alto.Approvals.Checkpoint,
        checkpoint_version: "conformance-1"
      )

    assert {:error, :approval_suspended, suspended} = Alto.run(%{}, opts)
    assert is_map(suspended.checkpoint)

    packet = suspended.checkpoint |> JSON.encode!() |> JSON.decode!()
    resumed = Keyword.put(opts, :checkpoint, {packet, :approve})
    assert {:ok, result} = Alto.run(%{}, resumed)
    assert result.output == "prepared"
    assert_receive {:prepared_ran, "prepared"}
  end

  test "child batch uses the selected runner and shared effect budget" do
    runner = Alto.Runner.Serial

    assert {:ok, result} =
             Alto.run(
               :parent,
               base_opts(runner,
                 loop: Alto.loop(SpawnLoop, subagents: Alto.Subagents.bounded(max_depth: 1)),
                 provider: {AnswerProvider, test_pid: self(), answer: "child"},
                 max_effects: 2
               )
             )

    assert {:completed, %{status: :ok, output: "child"}} = result.output
  end

  test "registry runs a configured selected runner through its public result surface" do
    runner = Alto.Runner.Serial
    name = String.to_atom("conformance-registry-#{System.unique_integer([:positive])}")

    resolver = fn
      "rule" ->
        {:ok,
         [
           runner: runner,
           loop: Alto.loop(RegistryLoop),
           tools: [RegistryTool],
           provider: nil
         ]}
    end

    start_supervised!({Alto.FrontEnd.Registry, name: name, config_resolver: resolver})
    assert {:ok, run_id} = Alto.FrontEnd.Registry.start_run(name, "rule", "{}")

    assert {:ok, %{output: :registry_ok}} = eventually_result(name, run_id)
  end

  test "manual Serial tickets admit one frame and stale tickets do not advance later frames" do
    assert {:ok, handle} =
             Alto.start(
               %{},
               base_opts(Alto.Runner.Serial,
                 loop: Alto.rule_loop(steps: ["registry_echo", "registry_echo"]),
                 tools: [RegistryTool],
                 runner_options: [mode: :manual, controller: self()]
               )
             )

    assert_receive {:alto_step_ready, first, %{pending_effects: 1}}, 2_000
    refute_receive {:tool_ran, _}, 100
    assert :ok = Alto.Runner.Serial.advance(first)
    assert_receive {:tool_ran, :registry}, 2_000

    # The actual tool has no side effect; receiving the next ticket proves the
    # first frame was admitted. A duplicate first ticket must be ignored.
    assert_receive {:alto_step_ready, second, _}, 2_000
    assert :ok = Alto.Runner.Serial.advance(first)
    refute_receive {:tool_ran, _}, 100
    assert :ok = Alto.Runner.Serial.advance(second)
    assert_receive {:tool_ran, :registry}, 2_000
    assert {:ok, %{output: [:registry_ok, :registry_ok]}} = Alto.await(handle, 2_000)

    assert {:ok, cancel_handle} =
             Alto.start(
               %{},
               base_opts(Alto.Runner.Serial,
                 loop: Alto.rule_loop(steps: ["registry_echo"]),
                 tools: [RegistryTool],
                 runner_options: [mode: :manual, controller: self()],
                 run_timeout: 5_000
               )
             )

    assert_receive {:alto_step_ready, _cancel_ticket, _}, 2_000
    assert :ok = Alto.cancel(cancel_handle, :manual_cancel)
    assert {:error, {:cancelled, :manual_cancel}, _} = Alto.await(cancel_handle, 2_000)

    assert {:ok, deadline_handle} =
             Alto.start(
               %{},
               base_opts(Alto.Runner.Serial,
                 loop: Alto.rule_loop(steps: ["registry_echo"]),
                 tools: [RegistryTool],
                 runner_options: [mode: :manual, controller: self()],
                 run_timeout: 50
               )
             )

    assert_receive {:alto_step_ready, _deadline_ticket, _}, 2_000
    assert {:error, :run_timeout, _} = Alto.await(deadline_handle, 2_000)

    parent = self()

    controller =
      spawn(fn ->
        receive do
          message ->
            send(parent, message)
            Process.sleep(:infinity)
        end
      end)

    assert {:ok, owner_handle} =
             Alto.start(
               %{},
               base_opts(Alto.Runner.Serial,
                 loop: Alto.rule_loop(steps: ["registry_echo"]),
                 tools: [RegistryTool],
                 runner_options: [mode: :manual, controller: controller]
               )
             )

    assert_receive {:alto_step_ready, _owner_ticket, _}, 2_000
    Process.exit(controller, :kill)
    assert {:error, {:cancelled, {:step_controller_down, _}}, _} = Alto.await(owner_handle, 2_000)
  end

  defp eventually_result(name, run_id, attempts \\ 100)
  defp eventually_result(_name, _run_id, 0), do: :timeout

  defp eventually_result(name, run_id, attempts) do
    case Alto.FrontEnd.Registry.run_result(name, run_id) do
      :running ->
        Process.sleep(10)
        eventually_result(name, run_id, attempts - 1)

      {:ok, result} ->
        result
    end
  end
end
