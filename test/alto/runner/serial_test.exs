defmodule Alto.Runner.SerialTest do
  use ExUnit.Case, async: true

  alias Alto.Event

  defmodule EchoTool do
    @behaviour Alto.Tool

    @impl true
    def name(_opts), do: :echo

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
    def execution_mode(_opts), do: :parallel

    @impl true
    def run(%{"value" => value}, _context, _opts), do: {:ok, %{echo: value}}
  end

  defmodule ToolThenAnswerProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_request, request})

      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        sink.(Event.live(:model_delta, %{text: "finished"}))
        {:ok, %{message: "finished", tool_calls: []}}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [
             %{id: "call-1", name: "echo", arguments_json: ~s({"value":"hello"})}
           ]
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
      send(Keyword.fetch!(opts, :test_pid), {:provider_started, self()})
      receive do: (:never -> :ok)
    end
  end

  defmodule AnswerProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_request, request})
      {:ok, %{message: "done", tool_calls: []}}
    end
  end

  defmodule DuplicateCallProvider do
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
           tool_calls: [
             %{id: "dup", name: "echo", arguments_json: ~s({"value":"one"})},
             %{id: "dup", name: "echo", arguments_json: ~s({"value":"two"})}
           ]
         }}
      end
    end
  end

  defmodule SafeEchoTool do
    use Alto.Tool, name: :echo, execution_mode: :parallel, approval: :never

    @impl true
    def schema(_opts), do: EchoTool.schema([])

    @impl true
    def run(arguments, context, _opts), do: EchoTool.run(arguments, context, [])
  end

  defmodule NonEncodableTool do
    @behaviour Alto.Tool

    defmodule Payload do
      defstruct [:value]
    end

    @impl true
    def name(_opts), do: :echo

    @impl true
    def schema(_opts), do: EchoTool.schema([])

    @impl true
    def execution_mode(_opts), do: :parallel

    @impl true
    def approval(_opts), do: :never

    @impl true
    def run(_arguments, _context, _opts), do: {:ok, %Payload{value: "x"}}
  end

  defmodule BlockingTool do
    use Alto.Tool, name: :echo, execution_mode: :parallel, approval: :never

    @impl true
    def schema(_opts), do: EchoTool.schema([])

    @impl true
    def run(_arguments, _context, _opts), do: receive(do: (:never -> {:ok, :done}))
  end

  defmodule ConfiguredEchoTool do
    use Alto.Tool, name: :echo, execution_mode: :parallel, approval: :never

    @impl true
    def schema(_opts), do: EchoTool.schema([])

    @impl true
    def run(%{"value" => value}, _context, opts) do
      {:ok, %{echo: value <> Keyword.fetch!(opts, :suffix)}}
    end
  end

  defmodule BlockingApproval do
    @behaviour Alto.Approval

    @impl true
    def decide(_request, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:approval_started, self()})
      receive do: (:never -> :approve)
    end
  end

  defmodule RecordingApproval do
    @behaviour Alto.Approval

    @impl true
    def decide(request, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:approval_decision, request})
      :approve
    end
  end

  defmodule PreparedEchoTool do
    @behaviour Alto.Tool

    @impl true
    def name(_opts), do: :echo

    @impl true
    def schema(_opts), do: EchoTool.schema([])

    @impl true
    def execution_mode(_opts), do: :parallel

    @impl true
    def prepare(%{"value" => value}, _context, opts) do
      token = make_ref()
      prepared = %{value: value, token: token}
      send(Keyword.fetch!(opts, :test_pid), {:tool_prepared, prepared})
      {:ok, prepared, %{canonical_value: String.upcase(value)}}
    end

    @impl true
    def run_prepared(prepared, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:prepared_executed, prepared})
      {:ok, %{echo: prepared.value}}
    end
  end

  defmodule ConfiguredPrepareTool do
    @behaviour Alto.Tool

    @impl true
    def name(_opts), do: :echo

    @impl true
    def schema(_opts), do: EchoTool.schema([])

    @impl true
    def execution_mode(_opts), do: :parallel

    @impl true
    def prepare(_arguments, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:prepare_attempted, self()})
      Keyword.fetch!(opts, :prepare_result)
    end

    @impl true
    def run_prepared(_prepared, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), :forbidden_run_prepared)
      {:ok, %{echo: "unreachable"}}
    end
  end

  defmodule BlockingPrepareTool do
    @behaviour Alto.Tool

    @impl true
    def name(_opts), do: :echo

    @impl true
    def schema(_opts), do: EchoTool.schema([])

    @impl true
    def execution_mode(_opts), do: :parallel

    @impl true
    def prepare(_arguments, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:prepare_started, self()})
      receive do: (:never -> :ok)
    end

    @impl true
    def run_prepared(_prepared, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), :forbidden_run_prepared)
      {:ok, %{echo: "unreachable"}}
    end
  end

  defmodule OnlyPrepareTool do
    @behaviour Alto.Tool

    @impl true
    def name(_opts), do: :echo

    @impl true
    def schema(_opts), do: EchoTool.schema([])

    @impl true
    def execution_mode(_opts), do: :parallel

    @impl true
    def prepare(_arguments, _context, _opts), do: {:ok, %{}, %{}}
  end

  defmodule OnlyRunPreparedTool do
    @behaviour Alto.Tool

    @impl true
    def name(_opts), do: :echo

    @impl true
    def schema(_opts), do: EchoTool.schema([])

    @impl true
    def execution_mode(_opts), do: :parallel

    @impl true
    def run_prepared(_prepared, _context, _opts), do: {:ok, %{echo: "unreachable"}}
  end

  test "executes one model/tool/model cycle in strict order" do
    parent = self()

    assert {:ok, result} =
             Alto.run("do the thing",
               provider: {ToolThenAnswerProvider, test_pid: parent},
               tools: [EchoTool],
               approval: Alto.Approvals.AllowAll,
               event_sink: fn event -> send(parent, {:event, event}) end
             )

    assert result.output == "finished"
    assert result.model_requests == 2

    assert Enum.map(result.events, & &1.type) == [
             :model_completed,
             :tool_completed,
             :step_settled,
             :model_completed,
             :step_settled
           ]

    assert_receive {:event, %Event{domain: :live, type: :model_started, data: %{step: 1}}}
    assert_receive {:provider_request, %{messages: [%{"role" => "user"}]}}

    assert_receive {:event, %Event{domain: :live, type: :model_started, data: %{step: 2}}}

    assert_receive {:provider_request,
                    %{
                      messages: [
                        %{"role" => "user"},
                        %{"role" => "assistant", "tool_calls" => [_call]},
                        %{"role" => "tool", "content" => tool_result}
                      ]
                    }}

    assert JSON.decode!(tool_result) == %{"echo" => "hello"}
    assert_receive {:event, %Event{domain: :live, type: :model_delta, data: %{text: "finished"}}}
  end

  test "returns a bounded error instead of starting another paid step" do
    assert {:error, {:model_step_limit, 1}, result} =
             Alto.run("loop once",
               provider: {ToolThenAnswerProvider, test_pid: self()},
               tools: [EchoTool],
               max_steps: 1
             )

    assert result.model_requests == 1
  end

  test "rejects an initial transcript over its hard limit" do
    assert {:error, {:transcript_limit, 8}, result} =
             Alto.run("too long", provider: ToolThenAnswerProvider, max_transcript_bytes: 8)

    assert result.model_requests == 0
  end

  test "denied approval becomes a tool result and does not run the tool" do
    parent = self()

    assert {:ok, result} =
             Alto.run("do not run it",
               provider: {ToolThenAnswerProvider, test_pid: parent},
               tools: [EchoTool],
               approval: {Alto.Approvals.DenyAll, reason: :not_allowed},
               event_sink: fn event -> send(parent, {:event, event}) end
             )

    assert result.output == "finished"

    assert Enum.map(result.events, & &1.type) == [
             :model_completed,
             :tool_failed,
             :step_settled,
             :model_completed,
             :step_settled
           ]

    assert_receive {:event, %Event{domain: :live, type: :approval_requested}}

    assert Enum.any?(result.messages, fn
             %{"role" => "tool", "content" => content} ->
               String.contains?(content, "approval_denied")

             _message ->
               false
           end)
  end

  test "tools marked approval never bypass the policy" do
    assert {:ok, result} =
             Alto.run("safe read",
               provider: {ToolThenAnswerProvider, test_pid: self()},
               tools: [SafeEchoTool],
               approval: Alto.Approvals.DenyAll
             )

    assert result.output == "finished"
    assert Enum.any?(result.events, &(&1.type == :tool_completed))
    refute Enum.any?(result.events, &(&1.type == :tool_failed))
  end

  test "configured tools receive their component options" do
    assert {:ok, result} =
             Alto.run("configured tool",
               provider: {ToolThenAnswerProvider, test_pid: self()},
               tools: [{ConfiguredEchoTool, suffix: "!"}]
             )

    assert result.output == "finished"
    assert Enum.any?(result.messages, &(&1["role"] == "tool" and &1["content"] =~ "hello!"))
  end

  test "prepares once before approval and executes the exact prepared value" do
    parent = self()

    assert {:ok, result} =
             Alto.run("prepare it",
               provider: {ToolThenAnswerProvider, test_pid: parent},
               tools: [{PreparedEchoTool, test_pid: parent}],
               approval: {RecordingApproval, test_pid: parent}
             )

    assert_receive {:tool_prepared, prepared}

    assert_receive {:approval_decision,
                    %Alto.Approval.Request{
                      arguments: %{"value" => "hello"},
                      details: %{canonical_value: "HELLO"}
                    }}

    assert_receive {:prepared_executed, ^prepared}
    refute_receive {:tool_prepared, _other}
    assert result.output == "finished"
  end

  test "cancellation interrupts an in-flight provider task" do
    assert {:ok, handle} =
             Alto.start("wait forever", provider: {BlockingProvider, test_pid: self()})

    assert_receive {:provider_started, provider_pid}
    monitor = Process.monitor(provider_pid)

    assert {:error, :await_timeout} = Alto.await(handle, 10)
    assert Process.alive?(Alto.Test.Runner.worker(handle))
    assert :ok = Alto.cancel(handle, :user)
    assert {:error, {:cancelled, :user}, result} = Alto.await(handle, 1_000)
    assert Enum.map(result.events, & &1.type) == [:run_cancelled]
    assert_receive {:DOWN, ^monitor, :process, ^provider_pid, _reason}
  end

  test "owner exit cooperatively cancels an in-flight run" do
    parent = self()

    owner =
      spawn(fn ->
        assert {:ok, handle} =
                 Alto.start("owned wait",
                   provider: {BlockingProvider, test_pid: parent},
                   owner: self()
                 )

        send(parent, {:owned_handle, handle})
        receive do: (:keep_alive -> :ok)
      end)

    assert_receive {:owned_handle, handle}
    task_monitor = Process.monitor(Alto.Test.Runner.worker(handle))
    assert_receive {:provider_started, provider_pid}
    provider_monitor = Process.monitor(provider_pid)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^task_monitor, :process, _pid, _reason}, 2_000
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider_pid, _reason}
  end

  test "cancellation interrupts an in-flight tool task" do
    parent = self()

    assert {:ok, handle} =
             Alto.start("block in tool",
               provider: {ToolThenAnswerProvider, test_pid: parent},
               tools: [BlockingTool],
               event_sink: fn event -> send(parent, {:event, event}) end
             )

    assert_receive {:event, %Event{domain: :live, type: :tool_started}}
    assert :ok = Alto.cancel(handle, :user)
    assert {:error, {:cancelled, :user}, result} = Alto.await(handle, 1_000)
    assert Enum.map(result.events, & &1.type) == [:model_completed, :tool_failed, :run_cancelled]
    assert Enum.find(result.events, &(&1.type == :tool_failed)).data.outcome == :unknown
    assert List.last(result.messages)["role"] == "tool"
  end

  test "cancellation interrupts approval before the tool starts" do
    assert {:ok, handle} =
             Alto.start("ask first",
               provider: {ToolThenAnswerProvider, test_pid: self()},
               tools: [EchoTool],
               approval: {BlockingApproval, test_pid: self()}
             )

    assert_receive {:approval_started, approval_pid}
    monitor = Process.monitor(approval_pid)

    assert :ok = Alto.cancel(handle, :operator_stop)

    assert {:error, {:cancelled, :operator_stop}, result} = Alto.await(handle, 1_000)
    assert Enum.map(result.events, & &1.type) == [:model_completed, :run_cancelled]
    refute Enum.any?(result.events, &(&1.type in [:tool_completed, :tool_failed]))
    assert_receive {:DOWN, ^monitor, :process, ^approval_pid, _reason}
  end

  test "prepare failures reject every invalid preparation result before approval" do
    cases = [
      {"prepare error", "fail prepare", {:error, :boom}, [], "boom"},
      {"malformed return", "bad return", :not_a_valid_return, [], "invalid_tool_prepare_return"},
      {"non-map details", "bad details", {:ok, %{value: "prepared"}, "not-a-map"}, [],
       "invalid_approval_details"},
      {"oversized details", "large details",
       {:ok, %{value: "prepared"}, %{summary: String.duplicate("x", 1_024)}},
       [max_approval_details_bytes: 64], {:approval_details_limit, 64}}
    ]

    for {label, prompt, prepare_result, options, expected_failure} <- cases do
      result = run_configured_prepare(prompt, prepare_result, options)

      assert result.output == "finished", label
      assert_receive {:prepare_attempted, _prepare_pid}, 1_000
      assert_prepare_failure(result, expected_failure)
      refute_receive {:approval_decision, _request}
      refute_receive {:event, %Event{type: :approval_requested}}
      refute_receive :forbidden_run_prepared
    end
  end

  defp run_configured_prepare(prompt, prepare_result, options) do
    parent = self()

    defaults = [
      provider: {ToolThenAnswerProvider, test_pid: parent},
      tools: [{ConfiguredPrepareTool, test_pid: parent, prepare_result: prepare_result}],
      approval: {RecordingApproval, test_pid: parent},
      event_sink: fn event -> send(parent, {:event, event}) end
    ]

    assert {:ok, result} = Alto.run(prompt, Keyword.merge(defaults, options))
    result
  end

  defp assert_prepare_failure(result, "boom") do
    assert Enum.map(result.events, & &1.type) == [
             :model_completed,
             :tool_failed,
             :step_settled,
             :model_completed,
             :step_settled
           ]

    assert Enum.any?(
             result.messages,
             &(&1["role"] == "tool" and JSON.decode!(&1["content"]) == %{"error" => "boom"})
           )
  end

  defp assert_prepare_failure(result, "invalid_tool_prepare_return"),
    do: assert(enum_has_tool_failure?(result, "invalid_tool_prepare_return"))

  defp assert_prepare_failure(result, "invalid_approval_details"),
    do: assert(enum_has_tool_failure?(result, "invalid_approval_details"))

  defp assert_prepare_failure(result, {:approval_details_limit, 64}) do
    assert Enum.any?(
             result.events,
             &(&1.type == :tool_failed and &1.data[:error] == {:approval_details_limit, 64})
           )
  end

  test "cancellation terminates an in-flight preparation task" do
    parent = self()

    assert {:ok, handle} =
             Alto.start("cancel in prepare",
               provider: {ToolThenAnswerProvider, test_pid: parent},
               tools: [{BlockingPrepareTool, test_pid: parent}],
               approval: {RecordingApproval, test_pid: parent},
               event_sink: fn event -> send(parent, {:event, event}) end
             )

    assert_receive {:prepare_started, prepare_pid}
    monitor = Process.monitor(prepare_pid)

    assert :ok = Alto.cancel(handle, :user)

    assert {:error, {:cancelled, :user}, result} = Alto.await(handle, 1_000)
    assert Enum.map(result.events, & &1.type) == [:model_completed, :run_cancelled]
    refute_receive {:approval_decision, _request}
    refute_receive {:event, %Event{type: :approval_requested}}
    refute_receive {:event, %Event{type: :tool_started}}
    assert_receive {:DOWN, ^monitor, :process, ^prepare_pid, _reason}
  end

  test "preparation timeout terminates its task and does not continue to approval" do
    parent = self()

    assert {:ok, result} =
             Alto.run("time out prepare",
               provider: {ToolThenAnswerProvider, test_pid: parent},
               tools: [{BlockingPrepareTool, test_pid: parent}],
               approval: {RecordingApproval, test_pid: parent},
               tool_timeout: 200,
               event_sink: fn event -> send(parent, {:event, event}) end
             )

    assert_receive {:prepare_started, prepare_pid}
    monitor = Process.monitor(prepare_pid)

    assert result.output == "finished"

    assert Enum.map(result.events, & &1.type) == [
             :model_completed,
             :tool_failed,
             :step_settled,
             :model_completed,
             :step_settled
           ]

    assert Enum.any?(
             result.events,
             &(&1.type == :tool_failed and
                 &1.data[:error] == {:tool_prepare_process_failed, :timeout})
           )

    refute_receive {:approval_decision, _request}
    refute_receive {:event, %Event{type: :approval_requested}}
    assert_receive {:DOWN, ^monitor, :process, ^prepare_pid, _reason}
  end

  test "tools implementing only one callback of a prepare/run_prepared pair are rejected" do
    parent = self()

    for module <- [OnlyPrepareTool, OnlyRunPreparedTool] do
      assert {:error, {:incomplete_tool_preparation_callbacks, ^module}, result} =
               Alto.run("construct",
                 provider: {ToolThenAnswerProvider, test_pid: parent},
                 tools: [module]
               )

      assert result.model_requests == 0
      assert result.events == []
    end

    refute_receive {:provider_request, _request}
  end

  test "unprepared tools use run/3 and expose arguments for approval" do
    parent = self()

    assert {:ok, result} =
             Alto.run("unprepared tool",
               provider: {ToolThenAnswerProvider, test_pid: parent},
               tools: [EchoTool],
               approval: {RecordingApproval, test_pid: parent},
               event_sink: fn event -> send(parent, {:event, event}) end
             )

    assert result.output == "finished"
    assert Enum.any?(result.events, &(&1.type == :tool_completed))

    assert_receive {:approval_decision,
                    %Alto.Approval.Request{
                      arguments: %{"value" => "hello"},
                      details: %{}
                    }}

    refute_receive {:prepare_attempted, _prepare_pid}
    refute_receive :forbidden_run_prepared
  end

  test "a non-encodable tool result stays a bounded tool message and does not fail the run" do
    parent = self()

    assert {:ok, result} =
             Alto.run("use a tool then answer",
               provider: {ToolThenAnswerProvider, test_pid: parent},
               tools: [NonEncodableTool]
             )

    assert result.output == "finished"
    assert enum_has_tool_failure?(result, "encoding_error")
  end

  test ":auto project instructions reach the system prompt from the workspace" do
    root = Path.join(System.tmp_dir!(), "alto-instr-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "AGENTS.md"), "Prefer exact edits in this repository.")
    parent = self()

    assert {:ok, _result} =
             Alto.run("answer",
               provider: {AnswerProvider, test_pid: parent},
               prompt: Alto.Prompts.Coding,
               cwd: root,
               project_instructions: :auto
             )

    assert_receive {:provider_request, %{messages: [system, _user]}}
    assert system["role"] == "system"
    assert system["content"] =~ "Prefer exact edits in this repository."
  end

  test "rejects invalid project instruction options" do
    assert {:error, {:invalid_project_instructions, 5}, _result} =
             Alto.run("answer", provider: AnswerProvider, project_instructions: 5)
  end

  test "duplicate model tool call ids settle after every invocation reports" do
    parent = self()

    assert {:ok, result} =
             Alto.run("duplicate calls",
               provider: {DuplicateCallProvider, test_pid: parent},
               tools: [SafeEchoTool]
             )

    assert result.output == "finished"

    assert Enum.count(result.events, &(&1.type == :tool_completed and &1.data.call_id == "dup")) ==
             2
  end

  test "retains only the newest durable events under the event log bound" do
    parent = self()

    assert {:ok, result} =
             Alto.run("use a tool then answer",
               provider: {ToolThenAnswerProvider, test_pid: parent},
               tools: [SafeEchoTool],
               max_events: 2
             )

    assert length(result.events) == 2
    assert result.events_dropped == 3
    assert Enum.any?(result.events, &(&1.type == :step_settled))
  end

  defp enum_has_tool_failure?(result, needle) do
    Enum.any?(result.events, &(&1.type == :tool_failed and inspect(&1.data[:error]) =~ needle)) or
      Enum.any?(result.messages, &(&1["role"] == "tool" and &1["content"] =~ needle))
  end

  test "a step_settled hook may run a tool before the next model request" do
    hook_effects = fn _event, _context ->
      [
        Alto.Effect.run_tool(%{
          id: "hook-echo",
          name: "echo",
          arguments_json: ~s({"value":"hook"})
        })
      ]
    end

    spec =
      Alto.default_loop()
      |> Alto.Loop.after_event(:step_settled, hook_effects)

    parent = self()

    assert {:ok, result} =
             Alto.run("use a tool then answer",
               loop: spec,
               provider: {ToolThenAnswerProvider, test_pid: parent},
               tools: [SafeEchoTool]
             )

    assert result.output == "finished"

    # The hook tool result becomes explicit native context for the next model
    # request; it must not impersonate a provider tool-call reply.
    assert_receive {:provider_request, _first_request}
    assert_receive {:provider_request, second_request}

    assert Enum.any?(second_request.messages, fn
             %{"role" => "user", "content" => content} ->
               content =~ "alto_native_tool_result" and content =~ "hook-echo"

             _message ->
               false
           end)

    refute Enum.any?(
             second_request.messages,
             &(&1["role"] == "tool" and &1["tool_call_id"] == "hook-echo")
           )

    assert Enum.any?(
             result.events,
             &(&1.type == :tool_completed and &1.data.call_id == "hook-echo")
           )
  end

  test "a step_settled hook tool failure is absorbed and the run continues" do
    hook_effects = fn _event, _context ->
      [Alto.Effect.run_tool(%{id: "hook-missing", name: "missing_tool", arguments_json: "{}"})]
    end

    spec =
      Alto.default_loop()
      |> Alto.Loop.after_event(:step_settled, hook_effects)

    parent = self()

    assert {:ok, result} =
             Alto.run("use a tool then answer",
               loop: spec,
               provider: {ToolThenAnswerProvider, test_pid: parent},
               tools: [SafeEchoTool]
             )

    assert result.output == "finished"

    assert Enum.any?(
             result.events,
             &(&1.type == :tool_failed and &1.data.call_id == "hook-missing")
           )
  end

  test "a hook tool effect after the final step keeps the stop result" do
    hook_effects = fn _event, _context ->
      [
        Alto.Effect.run_tool(%{
          id: "hook-echo",
          name: "echo",
          arguments_json: ~s({"value":"hook"})
        })
      ]
    end

    spec =
      Alto.default_loop()
      |> Alto.Loop.after_event(:step_settled, hook_effects)

    assert {:ok, result} =
             Alto.run("answer directly",
               loop: spec,
               provider: {AnswerProvider, test_pid: self()},
               tools: [SafeEchoTool]
             )

    assert result.output == "done"

    assert Enum.any?(
             result.events,
             &(&1.type == :tool_completed and &1.data.call_id == "hook-echo")
           )
  end
end
