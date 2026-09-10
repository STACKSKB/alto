defmodule Alto.Runner.SerialExposureTest do
  @moduledoc """
  : model exposure through delegation.

  Runtime capabilities (`tools`) vs model exposure (`model_tools`). Every
  registered tool is invokable via `invoke_tool`; only the effective subset
  reaches provider schemas. The subset is carried into child runs and
  intersected with inherited or narrowed capabilities, so a child can never
  widen its parent. Provider-originated `run_tool` calls outside the subset
  fail closed (`{:model_tool_not_exposed, name}`) without preparation,
  approval, or execution; native calls still use full capabilities.
  """

  use ExUnit.Case, async: true

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Transition

  defmodule EchoTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :echo
    @impl true
    def schema,
      do: %{
        description: "Echo.",
        parameters: %{type: "object", properties: %{value: %{type: "string"}}}
      }

    @impl true
    def execution_mode, do: :parallel
    @impl true
    def approval, do: :never
    @impl true
    def run(%{"value" => v}, _ctx), do: {:ok, %{echo: v}}
  end

  defmodule HiddenTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :hidden
    @impl true
    def schema, do: %{description: "Hidden.", parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode, do: :parallel
    @impl true
    def approval, do: :never
    @impl true
    def run(_args, _ctx), do: {:ok, %{hid: true}}
  end

  defmodule GuardedHiddenTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :hidden
    @impl true
    def schema, do: HiddenTool.schema()
    @impl true
    def execution_mode, do: :parallel
    @impl true
    def approval, do: :required
    @impl true
    def run(_args, ctx, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:hidden_ran, ctx.session_id})
      {:ok, %{hid: true}}
    end
  end

  defmodule CaptureProvider do
    @behaviour Alto.Provider
    @impl true
    def describe(_o), do: %{}
    @impl true
    def stream(request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:seen_tools, request.tools})
      {:ok, %{message: "done", tool_calls: []}}
    end
  end

  defmodule HiddenCallProvider do
    @behaviour Alto.Provider
    @impl true
    def describe(_o), do: %{}
    @impl true
    def stream(request, _sink, _opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        {:ok, %{message: "done", tool_calls: []}}
      else
        {:ok,
         %{message: nil, tool_calls: [%{id: "c-hidden", name: "hidden", arguments_json: "{}"}]}}
      end
    end
  end

  defmodule HiddenInvokeLoop do
    @behaviour Alto.Loop
    @impl true
    def init(_task, _spec) do
      Transition.continue(%{}, [
        Effect.invoke_tool(%{id: "hid-1", name: "hidden", arguments: %{}})
      ])
    end

    @impl true
    def handle_event(%Event{type: :tool_completed, data: %{value: v}}, _s, _),
      do: Transition.stop(%{}, v)

    def handle_event(%Event{type: :tool_failed, data: data}, s, _),
      do: Transition.stop(s, {:failed, data})

    def handle_event(_e, s, _), do: Transition.continue(s)
  end

  defmodule SpawnOnceLoop do
    @behaviour Alto.Loop
    @impl true
    def init(%{spawn: spawn}, _spec), do: Transition.continue(%{}, [Effect.spawn_agent(spawn)])
    @impl true
    def handle_event(%Event{type: :subagent_completed, data: data}, s, _),
      do: Transition.stop(s, {:completed, data})

    def handle_event(%Event{type: :subagent_failed, data: data}, s, _),
      do: Transition.stop(s, {:failed, data})

    def handle_event(_e, s, _), do: Transition.continue(s)
  end

  defp parent_loop(depth),
    do: Alto.loop(SpawnOnceLoop, subagents: Alto.Subagents.bounded(max_depth: depth))

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-s03-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "parent with model_tools: [] exposes no schemas in descendants", %{dir: dir} do
    test_pid = self()

    assert {:ok, result} =
             Alto.run(%{spawn: %{id: "sub-1", task: "child"}},
               loop: parent_loop(1),
               provider: {CaptureProvider, test_pid: test_pid},
               tools: [EchoTool, HiddenTool],
               model_tools: [],
               session: :new,
               session_dir: dir
             )

    # The parent delegates without a model request; the child (default loop)
    # is the only model caller and must see zero schemas.
    assert_receive {:seen_tools, []}

    assert {:completed, %{id: "sub-1", status: :ok}} = result.output
  end

  test "child inherits the narrowed subset and cannot widen", %{dir: dir} do
    test_pid = self()

    # Parent exposes only echo; child explicitly lists both tools and asks
    # for both, but the effective child exposure stays {echo}.
    child_provider = {CaptureProvider, test_pid: test_pid}

    assert {:ok, result} =
             Alto.run(
               %{
                 spawn: %{
                   id: "sub-1",
                   task: "hi",
                   tools: [EchoTool, HiddenTool],
                   model_tools: ["echo", "hidden"],
                   provider: child_provider
                 }
               },
               loop: parent_loop(1),
               provider: {CaptureProvider, test_pid: test_pid},
               tools: [EchoTool, HiddenTool],
               model_tools: ["echo"],
               session: :new,
               session_dir: dir
             )

    assert {:completed, %{status: :ok}} = result.output

    # Only the child makes a model request; it must see echo alone.
    assert_receive {:seen_tools, child_tools}
    assert Enum.map(child_tools, &get_in(&1, ["function", "name"])) == ["echo"]
  end

  test "fabricated hidden tool calls are rejected without execution", %{dir: _dir} do
    test_pid = self()

    # Provider tries to call hidden though only echo is exposed.
    assert {:ok, result} =
             Alto.run("go",
               provider: {HiddenCallProvider, []},
               tools: [EchoTool, {GuardedHiddenTool, test_pid: test_pid}],
               model_tools: ["echo"],
               approval: Alto.Approvals.AllowAll
             )

    assert result.output == "done"

    assert Enum.any?(
             result.events,
             &(&1.type == :tool_failed and &1.data.error == {:model_tool_not_exposed, "hidden"})
           )

    refute_received {:hidden_ran, _}
  end

  test "native hidden-tool invocation still uses runtime capabilities", %{dir: _dir} do
    assert {:ok, result} =
             Alto.run("go",
               loop: Alto.loop(HiddenInvokeLoop),
               tools: [EchoTool, HiddenTool],
               model_tools: ["echo"]
             )

    assert result.output == %{hid: true}
  end

  test "provider substitution in the child still respects the parent subset", %{dir: dir} do
    test_pid = self()

    # Parent exposes only echo. Child swaps providers but still cannot get
    # hidden schemas.
    defmodule ChildCapture do
      @behaviour Alto.Provider
      @impl true
      def describe(_o), do: %{}
      @impl true
      def stream(request, _sink, opts) do
        send(Keyword.fetch!(opts, :test_pid), {:child_tools, request.tools})
        {:ok, %{message: "child done", tool_calls: []}}
      end
    end

    assert {:ok, _} =
             Alto.run(
               %{spawn: %{id: "sub-1", task: "hi", provider: {ChildCapture, test_pid: test_pid}}},
               loop: parent_loop(1),
               provider: {CaptureProvider, test_pid: test_pid},
               tools: [EchoTool, HiddenTool],
               model_tools: ["echo"],
               session: :new,
               session_dir: dir
             )

    # Parent never makes a model request (delegation loop); the child does.
    refute_received {:seen_tools, _}
    assert_receive {:child_tools, child_tools}
    assert Enum.map(child_tools, &get_in(&1, ["function", "name"])) == ["echo"]
  end

  test "approvals and cancellation are unchanged for exposed tools", %{dir: dir} do
    test_pid = self()

    defmodule GuardedEcho do
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
      def run(%{"value" => v}, ctx, opts) do
        send(Keyword.fetch!(opts, :test_pid), {:echo_ran, v, ctx.session_id})
        {:ok, %{echo: v}}
      end
    end

    defmodule EchoCallProvider do
      @behaviour Alto.Provider
      @impl true
      def describe(_o), do: %{}
      @impl true
      def stream(request, _sink, _opts) do
        if Enum.any?(request.messages, &(&1["role"] == "tool")) do
          {:ok, %{message: "done", tool_calls: []}}
        else
          {:ok,
           %{
             message: nil,
             tool_calls: [%{id: "c1", name: "echo", arguments_json: ~s({"value":"hi"})}]
           }}
        end
      end
    end

    # Approval still gates the exposed tool inside the child.
    assert {:ok, result} =
             Alto.run(%{spawn: %{id: "sub-1", task: "hi", provider: {EchoCallProvider, []}}},
               loop: parent_loop(1),
               provider: {CaptureProvider, test_pid: test_pid},
               tools: [{GuardedEcho, test_pid: test_pid}],
               model_tools: ["echo"],
               approval: Alto.Approvals.DenyAll,
               session: :new,
               session_dir: dir
             )

    assert {:completed, %{status: :ok}} = result.output
    refute_received {:echo_ran, _, _}
  end
end
