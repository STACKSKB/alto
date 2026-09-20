defmodule Alto.Runner.SerialNativeBoundsTest do
  @moduledoc """
  Bounded native tool results and provider-facing encodings.

  `output` is the provider-facing encoding (bounded string, truncated
  with a marker). `value` is the native term, bounded by
  `max_tool_result_bytes` via `:erlang.external_size/1` before event
  retention, fanout, or session persistence. Oversize natives become a bounded
  `tool_failed` (`{:tool_result_too_large, %{limit:, size:}}`); the tool ran
  exactly once and that fact is retained.
  """

  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.Protocol
  alias Alto.Session

  defmodule BigTool do
    @behaviour Alto.Tool
    @impl true
    def name(_opts), do: :big
    @impl true
    def schema(_opts), do: %{description: "Big.", parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode(_opts), do: :parallel
    @impl true
    def approval(_opts), do: :never
    @impl true
    def run(_args, _ctx, _opts) do
      {:ok, String.duplicate("x", 100_000)}
    end
  end

  defmodule NestedBigTool do
    @behaviour Alto.Tool
    @impl true
    def name(_opts), do: :nested
    @impl true
    def schema(_opts),
      do: %{description: "Nested.", parameters: %{type: "object", properties: %{}}}

    @impl true
    def execution_mode(_opts), do: :parallel
    @impl true
    def approval(_opts), do: :never
    @impl true
    def run(_args, _ctx, _opts) do
      {:ok, %{level1: %{level2: [%{payload: String.duplicate("y", 100_000)}]}}}
    end
  end

  defmodule TupleTool do
    @behaviour Alto.Tool
    @impl true
    def name(_opts), do: :tup
    @impl true
    def schema(_opts), do: %{description: "Tup.", parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode(_opts), do: :parallel
    @impl true
    def approval(_opts), do: :never
    @impl true
    def run(_args, _ctx, _opts), do: {:ok, {:tuple_ok, 1, 2}}
  end

  defmodule MalformedTool do
    @behaviour Alto.Tool
    @impl true
    def name(_opts), do: :malformed
    @impl true
    def schema(_opts),
      do: %{description: "Malformed.", parameters: %{type: "object", properties: %{}}}

    @impl true
    def execution_mode(_opts), do: :parallel
    @impl true
    def approval(_opts), do: :never
    @impl true
    def run(_args, _ctx, _opts), do: {:unexpected, %{nested: String.duplicate("m", 100_000)}}
  end

  defmodule GuardedBigTool do
    @behaviour Alto.Tool
    @impl true
    def name(_opts), do: :big
    @impl true
    def schema(_opts), do: BigTool.schema([])
    @impl true
    def execution_mode(_opts), do: :exclusive
    @impl true
    def approval(_opts), do: :required
    @impl true
    def run(_args, ctx, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:tool_ran, ctx.session_id})
      {:ok, String.duplicate("z", 100_000)}
    end
  end

  defmodule SingleToolLoop do
    @behaviour Alto.Loop
    @impl true
    def init(_task, spec) do
      id = Keyword.fetch!(spec.driver_options, :call_id)
      name = Keyword.fetch!(spec.driver_options, :tool)

      Alto.Transition.continue(%{}, [
        Alto.Effect.invoke_tool(%{id: id, name: name, arguments: %{}})
      ])
    end

    @impl true
    def handle_event(%Event{type: :tool_completed, data: data}, s, _),
      do: Alto.Transition.stop(s, {:completed, data})

    def handle_event(%Event{type: :tool_failed, data: data}, s, _),
      do: Alto.Transition.stop(s, {:failed, data})

    def handle_event(_event, state, _spec), do: Alto.Transition.continue(state)
  end

  defmodule ToolThenBigProvider do
    @behaviour Alto.Provider
    @impl true
    def describe(_o), do: %{}
    @impl true
    def stream(request, _sink, _opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        {:ok, %{message: "finished", tool_calls: []}}
      else
        {:ok, %{message: nil, tool_calls: [%{id: "call-big", name: "big", arguments_json: "{}"}]}}
      end
    end
  end

  test "100-byte limit cannot retain a 100KB raw result (provider-less)" do
    assert {:ok, result} =
             Alto.run("go",
               loop: Alto.loop(SingleToolLoop, call_id: "big-1", tool: "big"),
               tools: [BigTool],
               max_tool_result_bytes: 100
             )

    assert {:failed, %{error: {:tool_result_too_large, %{limit: 100, size: size}}}} =
             result.output

    assert size > 100_000

    assert Enum.any?(result.events, &(&1.type == :tool_failed))
    refute Enum.any?(result.events, &(&1.type == :tool_completed))

    failed = Enum.find(result.events, &(&1.type == :tool_failed))
    assert failed.data.call_id == "big-1"
    assert is_binary(failed.data.operation_id)
    refute Map.has_key?(failed.data, :value)
    refute inspect(failed.data) =~ String.duplicate("x", 1_000)
  end

  test "nested terms are measured, not just top-level bytes" do
    assert {:ok, result} =
             Alto.run("go",
               loop: Alto.loop(SingleToolLoop, call_id: "n-1", tool: "nested"),
               tools: [NestedBigTool],
               max_tool_result_bytes: 100
             )

    assert {:failed, %{error: {:tool_result_too_large, %{limit: 100}}}} = result.output
    refute Enum.any?(result.events, &(&1.type == :tool_completed))
  end

  test "malformed post-dispatch returns are bounded and remain uncertain" do
    assert {:ok, result} =
             Alto.run("go",
               loop: Alto.loop(SingleToolLoop, call_id: "malformed-1", tool: "malformed"),
               tools: [MalformedTool],
               max_tool_result_bytes: 100
             )

    assert {:failed, %{error: {:tool_failure_too_large, %{limit: 100}}}} = result.output
    failed = Enum.find(result.events, &(&1.type == :tool_failed))
    assert failed.data.outcome == :unknown
    assert failed.data.operation_id
    refute inspect(failed.data) =~ String.duplicate("m", 1_000)
  end

  test "small non-JSON values remain available through provider encoding" do
    assert {:ok, result} =
             Alto.run("go",
               loop: Alto.loop(SingleToolLoop, call_id: "t-1", tool: "tup"),
               tools: [TupleTool]
             )

    assert {:completed, %{value: {:tuple_ok, 1, 2}, output: output}} = result.output
    assert is_binary(output)
  end

  test "hybrid loop: oversize provider tool becomes bounded failure in transcript" do
    parent = self()

    assert {:ok, result} =
             Alto.run("go",
               provider: {ToolThenBigProvider, []},
               tools: [BigTool],
               max_tool_result_bytes: 100,
               event_sink: fn e -> send(parent, {:event, e}) end
             )

    assert result.output == "finished"

    assert Enum.any?(
             result.events,
             &(&1.type == :tool_failed and match?({:tool_result_too_large, _}, &1.data.error))
           )

    tool_msg = Enum.find(result.messages, &(&1["role"] == "tool"))
    assert tool_msg["tool_call_id"] == "call-big"
    assert byte_size(tool_msg["content"]) <= 500
    refute tool_msg["content"] =~ String.duplicate("x", 1_000)
  end

  test "persisted events never contain the raw large value" do
    dir = Path.join(System.tmp_dir!(), "alto-s02-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, result} =
             Alto.run("go",
               loop: Alto.loop(SingleToolLoop, call_id: "big-1", tool: "big"),
               tools: [BigTool],
               max_tool_result_bytes: 100,
               session: :new,
               session_dir: dir
             )

    assert result.session_id != nil
    assert {:ok, records} = Session.read(result.session_id, session_dir: dir)

    event_records = Enum.filter(records, &(&1["type"] == "event"))
    assert event_records != []

    for rec <- event_records do
      assert {:ok, data} = Session.decode_term(rec["data"])
      refute inspect(data) =~ String.duplicate("x", 1_000)
      # The stored failure carries only the bounded error, never :value.
      if rec["event"] == "tool_failed" do
        assert match?({:tool_result_too_large, _}, data.error)
        refute Map.has_key?(data, :value)
      end
    end
  end

  test "frontend encoding of the failure stays within the line bound" do
    assert {:ok, result} =
             Alto.run("go",
               loop: Alto.loop(SingleToolLoop, call_id: "big-1", tool: "big"),
               tools: [BigTool],
               max_tool_result_bytes: 100
             )

    failed = Enum.find(result.events, &(&1.type == :tool_failed))
    assert {:ok, line} = Protocol.event("s-1", "run-1", 1, failed, 1_048_576)
    assert IO.iodata_length(line) < 5_000
  end

  test "native failure reasons are bounded before event retention" do
    defmodule HugeFailureTool do
      @behaviour Alto.Tool
      def name(_opts), do: :huge_failure
      def schema(_opts), do: %{parameters: %{type: "object", properties: %{}}}
      def execution_mode(_opts), do: :exclusive
      def approval(_opts), do: :never
      def run(_args, _ctx, _opts), do: {:error, String.duplicate("x", 100_000)}
    end

    assert {:error, _, result} =
             Alto.run(%{},
               loop: Alto.rule_loop(steps: ["huge_failure"]),
               tools: [HugeFailureTool],
               max_tool_result_bytes: 100
             )

    failed = Enum.find(result.events, &(&1.type == :tool_failed))
    assert :erlang.external_size(failed.data.error) <= 100
  end

  test "size failure after a mutating tool does not re-execute and preserves knowledge" do
    test_pid = self()

    assert {:ok, result} =
             Alto.run("go",
               loop: Alto.loop(SingleToolLoop, call_id: "big-1", tool: "big"),
               tools: [{GuardedBigTool, test_pid: test_pid}],
               approval: Alto.Approvals.AllowAll,
               max_tool_result_bytes: 100
             )

    assert {:failed, %{error: {:tool_result_too_large, _}, call_id: "big-1", name: "big"}} =
             result.output

    # Exactly one execution despite the size failure.
    assert_received {:tool_ran, _run_id}
    refute_received {:tool_ran, _}

    # Knowledge that the tool ran is retained as a durable failure, not erased.
    assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.name == "big"))
  end
end
