defmodule Alto.Runner.SerialRuleLoopTest do
  @moduledoc """
  Provider-less rule-loop support in the serial host.

  The harness supports rule-based loops (cron triggers, queue consumers,
  watchers) that perform bounded tool workflows without a provider. See the
  model-independent harness boundary.

  Generic runs keep every host-owned guarantee — approval, prepared
  operations, bounds, supervision, cancellation — while model-specific state
  (provider, prompt, transcript) stays out of rule runs. A rule loop that
  requests a model effect without a provider fails closed with
  `:provider_required`, and prompt options without a provider are rejected at
  construction.
  """

  use ExUnit.Case, async: true

  alias Alto.Approval.Request, as: ApprovalRequest
  alias Alto.Effect
  alias Alto.Event
  alias Alto.Transition

  defmodule RuleEchoTool do
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
    def schema, do: RuleEchoTool.schema()

    @impl true
    def execution_mode, do: :exclusive

    # No approval/0 callback: defaults to :required, exercising the default.
    @impl true
    def run(%{"value" => value}, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:tool_ran, value})
      {:ok, %{echo: value}}
    end
  end

  defmodule RuleStampTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :stamp

    @impl true
    def schema do
      %{
        description: "Stamp a value.",
        parameters: %{
          type: "object",
          properties: %{value: %{type: "string"}},
          required: ["value"]
        }
      }
    end

    @impl true
    def execution_mode, do: :exclusive

    # Approval/0 omitted: defaults to :required, so the prepared invocation
    # crosses the approval boundary before run_prepared consumes it.
    @impl true
    def prepare(%{"value" => value}, _context) do
      token = "prep-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
      {:ok, %{value: value, token: token}, %{stamped_with: value, token: token}}
    end

    @impl true
    def run_prepared(%{value: value, token: token}, _context) do
      {:ok, %{stamped: value, token: token}}
    end
  end

  defmodule RecordingApproval do
    @behaviour Alto.Approval

    @impl true
    def decide(request, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:approval_decision, request})
      Keyword.fetch!(opts, :decision)
    end
  end

  # A finite rule loop: init receives the task (a list of values) and requests
  # one echo invocation per value, stopping once every tool result arrived.
  defmodule CountingRuleLoop do
    @behaviour Alto.Loop

    @impl true
    def init(calls, _spec) when is_list(calls) do
      request_next(%{pending: calls, results: []})
    end

    @impl true
    def handle_event(%Event{type: :tool_completed, data: %{output: output}}, state, _spec) do
      state |> Map.update!(:results, &[output | &1]) |> request_next()
    end

    def handle_event(%Event{type: :tool_failed, data: %{error: error}}, state, _spec) do
      state
      |> Map.update!(:results, &[{:error, error} | &1])
      |> then(&Transition.stop(&1, Enum.reverse(&1.results)))
    end

    def handle_event(_event, state, _spec), do: Transition.continue(state)

    defp request_next(%{pending: []} = state),
      do: Transition.stop(state, Enum.reverse(state.results))

    defp request_next(%{pending: [value | rest]} = state) do
      call = %{
        id: "rule-#{length(state.results) + 1}",
        name: "echo",
        arguments_json: JSON.encode!(%{value: value})
      }

      Transition.continue(%{state | pending: rest}, [Effect.run_tool(call)])
    end
  end

  defmodule ArgsEchoTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :echo_args

    @impl true
    def schema do
      %{
        description: "Report whether the tuple key survived as a native term.",
        parameters: %{
          type: "object",
          properties: %{},
          additionalProperties: true
        }
      }
    end

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :never

    @impl true
    def run(arguments, _context) when is_map(arguments) do
      {:ok, %{tuple_is_tuple: is_tuple(Map.get(arguments, :tuple))}}
    end
  end

  defmodule NativeRuleLoop do
    @behaviour Alto.Loop

    @impl true
    def init(:tuple_args, _spec) do
      call = %{:name => "echo_args", :arguments => %{"string_key" => "v", tuple: {1, 2}}}

      Transition.continue(%{}, [Effect.invoke_tool(call)])
    end

    def init(:bad_args, _spec) do
      Transition.continue(%{}, [Effect.invoke_tool(%{name: "echo", arguments: "not a map"})])
    end

    def init(:guarded, _spec) do
      Transition.continue(%{}, [
        Effect.invoke_tool(%{id: "invoke-1", name: "echo", arguments: %{"value" => "x"}})
      ])
    end

    @impl true
    def handle_event(%Event{type: :tool_completed, data: %{output: output}}, _state, _spec) do
      Transition.stop(%{}, output)
    end

    def handle_event(%Event{type: :tool_failed, data: %{error: error}}, _state, _spec) do
      Transition.stop(%{}, {:error, error})
    end

    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  # A rule loop that wrongly requests a model effect: the host must fail
  # closed instead of crashing on the missing provider.
  defmodule ModelRequestRuleLoop do
    @behaviour Alto.Loop

    @impl true
    def init(_task, _spec),
      do: Transition.continue(:requesting, [Effect.request_model(%{})])

    @impl true
    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  defmodule StampRuleLoop do
    @behaviour Alto.Loop

    @impl true
    def init(value, _spec) do
      call = %{id: "rule-stamp", name: "stamp", arguments_json: JSON.encode!(%{value: value})}
      Transition.continue(:requesting, [Effect.run_tool(call)])
    end

    @impl true
    def handle_event(%Event{type: :tool_completed, data: %{output: output}}, state, _spec) do
      Transition.stop(state, output)
    end

    def handle_event(%Event{type: :tool_failed, data: %{error: error}}, state, _spec) do
      Transition.stop(state, {:error, error})
    end

    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  test "a rule loop that requests a model effect without a provider fails closed" do
    assert {:error, :provider_required, result} =
             Alto.run("hello", loop: Alto.loop(ModelRequestRuleLoop), tools: [RuleEchoTool])

    assert result.messages == []
    assert result.events == []
    assert result.model_requests == 0
  end

  test "the default model loop without a provider fails closed at its model effect" do
    assert {:error, :provider_required, result} = Alto.run("hello")

    assert result.messages == []
    assert result.events == []
    assert result.model_requests == 0
  end

  test "prompt options are rejected for provider-less runs at construction" do
    for prompt_opts <- [[system_prompt: "beep"], [prompt: Alto.Prompts.Coding]] do
      opts =
        Keyword.merge([loop: Alto.loop(CountingRuleLoop), tools: [RuleEchoTool]], prompt_opts)

      assert {:error, :prompt_options_require_provider, result} = Alto.run("hello", opts)

      assert result.events == []
      assert result.messages == []
    end
  end

  test "project instructions are inert model state for provider-less runs" do
    assert {:ok, result} =
             Alto.run(["hello"],
               loop: Alto.loop(CountingRuleLoop),
               tools: [RuleEchoTool],
               project_instructions: :auto
             )

    assert result.output == [~s({"echo":"hello"})]
  end

  test "a rule loop performs a bounded tool workflow with no provider configured" do
    parent = self()

    assert {:ok, result} =
             Alto.run(["a", "b"],
               loop: Alto.loop(CountingRuleLoop),
               tools: [RuleEchoTool],
               event_sink: fn event -> send(parent, {:event, event}) end
             )

    # Tool result content is the bounded encoded value, one per invocation.
    assert result.output == [~s({"echo":"a"}), ~s({"echo":"b"})]
    assert result.messages == []
    assert result.model_requests == 0
    assert Enum.map(result.events, & &1.type) == [:tool_completed, :tool_completed]

    # The host emitted live tool lifecycle events but no model events.
    events = received_events()

    assert Enum.any?(
             events,
             &(&1.type == :tool_started and &1.data[:call_id] == "rule-1")
           )

    refute Enum.any?(events, &(&1.type in [:model_started, :model_completed]))
  end

  test "invoke_tool passes a native map to the tool with no JSON round-trip" do
    # A JSON round-trip would degrade the {1, 2} tuple to [1, 2]; a native
    # invocation must deliver the exact term.
    assert {:ok, result} =
             Alto.run(:tuple_args,
               loop: Alto.loop(NativeRuleLoop),
               tools: [ArgsEchoTool]
             )

    assert result.output == ~s({"tuple_is_tuple":true})
    assert result.messages == []
    assert result.model_requests == 0
  end

  test "invoke_tool rejects non-map arguments as a bounded tool failure" do
    assert {:ok, result} =
             Alto.run(:bad_args,
               loop: Alto.loop(NativeRuleLoop),
               tools: [RuleEchoTool]
             )

    assert result.output == {:error, {:tool_arguments_not_map, "not a map"}}
    assert Enum.any?(result.events, &(&1.type == :tool_failed))
  end

  test "invoke_tool crosses the host-owned approval boundary" do
    assert {:ok, result} =
             Alto.run(:guarded,
               loop: Alto.loop(NativeRuleLoop),
               tools: [{GuardedEchoTool, test_pid: self()}]
             )

    # DenyAll is the library default; the invocation never reaches the tool.
    assert result.output == {:error, {:approval_denied, :policy_denied}}
    refute_receive {:tool_ran, _value}
  end

  test "rule-loop invocations still cross the host-owned approval boundary on approval" do
    parent = self()

    assert {:ok, result} =
             Alto.run(["hello"],
               loop: Alto.loop(CountingRuleLoop),
               tools: [{GuardedEchoTool, test_pid: parent}],
               approval: {RecordingApproval, test_pid: parent, decision: :approve},
               event_sink: fn event -> send(parent, {:event, event}) end
             )

    assert result.output == [~s({"echo":"hello"})]

    assert_receive {:approval_decision,
                    %ApprovalRequest{
                      call_id: "rule-1",
                      tool: "echo",
                      arguments: %{"value" => "hello"},
                      details: %{}
                    } = request}

    assert is_binary(request.id)
    assert request.operation_id == request.id
    assert is_binary(request.run_id)

    assert_receive {:tool_ran, "hello"}

    events = received_events()
    assert Enum.any?(events, &(&1.type == :approval_requested))
    assert Enum.any?(events, &(&1.type == :approval_resolved and &1.data.decision == :approved))
  end

  test "a denial is a tool result and never performs the effect" do
    parent = self()

    assert {:ok, result} =
             Alto.run(["hello"],
               loop: Alto.loop(CountingRuleLoop),
               tools: [{GuardedEchoTool, test_pid: parent}],
               approval: {RecordingApproval, test_pid: parent, decision: {:deny, :not_allowed}},
               event_sink: fn event -> send(parent, {:event, event}) end
             )

    assert result.output == [{:error, {:approval_denied, :not_allowed}}]
    assert Enum.map(result.events, & &1.type) == [:tool_failed]

    assert Enum.any?(
             result.events,
             &(&1.type == :tool_failed and &1.data[:error] == {:approval_denied, :not_allowed})
           )

    assert Enum.any?(
             received_events(),
             &(&1.type == :approval_resolved and &1.data.decision == {:denied, :not_allowed})
           )

    refute_receive {:tool_ran, _value}
  end

  test "prepared tools resolve before approval and execute the frozen value" do
    assert {:ok, result} =
             Alto.run("frozen",
               loop: Alto.loop(StampRuleLoop),
               tools: [RuleStampTool],
               approval: {RecordingApproval, test_pid: self(), decision: :approve}
             )

    # Approval receives the display-safe details from prepare, not the opaque value.
    assert_receive {:approval_decision,
                    %ApprovalRequest{
                      call_id: "rule-stamp",
                      tool: "stamp",
                      arguments: %{"value" => "frozen"},
                      details: %{stamped_with: "frozen", token: token}
                    } = request}

    assert is_binary(request.id)
    assert request.operation_id == request.id

    # run_prepared consumed exactly the frozen value prepare returned: the
    # result carries the same token, so it cannot come from a second preparation.
    assert {:ok, %{"stamped" => "frozen", "token" => ^token}} = JSON.decode(result.output)
  end

  test "tool_completed carries the native value alongside the encoded output" do
    parent = self()

    assert {:ok, _result} =
             Alto.run(["a"],
               loop: Alto.loop(CountingRuleLoop),
               tools: [RuleEchoTool],
               event_sink: fn event -> send(parent, {:event, event}) end
             )

    events = received_events()
    completed = Enum.find(events, &(&1.type == :tool_completed))

    assert %{output: output, value: %{echo: "a"}} = completed.data
    assert output == ~s({"echo":"a"})
  end

  test "model_tools projects a subset to the provider while all tools stay invokable" do
    defmodule TwoToolProvider do
      @behaviour Alto.Provider
      @impl true
      def describe(_opts), do: %{}
      @impl true
      def stream(request, _sink, opts) do
        send(Keyword.fetch!(opts, :test_pid), {:seen_tools, request.tools})
        {:ok, %{message: "done", tool_calls: []}}
      end
    end

    defmodule HiddenTool do
      @behaviour Alto.Tool
      @impl true
      def name, do: :hidden
      @impl true
      def schema, do: %{parameters: %{type: "object", properties: %{}}}
      @impl true
      def execution_mode, do: :parallel
      @impl true
      def approval, do: :never
      @impl true
      def run(_args, _ctx), do: {:ok, %{hid: true}}
    end

    parent = self()

    assert {:ok, _} =
             Alto.run("hi",
               tools: [RuleEchoTool, HiddenTool],
               model_tools: ["echo"],
               provider: {TwoToolProvider, test_pid: parent}
             )

    assert_receive {:seen_tools, tools}
    assert Enum.map(tools, &get_in(&1, ["function", "name"])) == ["echo"]

    # The hidden tool is still a runtime capability via invoke_tool.
    defmodule HiddenInvokeLoop do
      @behaviour Alto.Loop
      @impl true
      def init(_task, _spec) do
        Alto.Transition.continue(%{}, [
          Alto.Effect.invoke_tool(%{id: "hid-1", name: "hidden", arguments: %{}})
        ])
      end

      @impl true
      def handle_event(%Alto.Event{type: :tool_completed, data: %{value: value}}, _s, _spec) do
        Alto.Transition.stop(%{}, value)
      end

      def handle_event(_event, state, _spec), do: Alto.Transition.continue(state)
    end

    assert {:ok, result} =
             Alto.run("go",
               loop: Alto.loop(HiddenInvokeLoop),
               tools: [RuleEchoTool, HiddenTool]
             )

    assert result.output == %{hid: true}

    assert {:error, {:unknown_model_tool, "missing"}, _} =
             Alto.run("hi",
               tools: [RuleEchoTool],
               model_tools: ["missing"],
               provider: {TwoToolProvider, test_pid: parent}
             )
  end

  defp received_events do
    Enum.reduce_while(1..200, [], fn _n, acc ->
      receive do
        {:event, %Event{} = event} -> {:cont, [event | acc]}
      after
        0 -> {:halt, Enum.reverse(acc)}
      end
    end)
  end
end
