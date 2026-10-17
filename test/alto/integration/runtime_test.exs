defmodule Alto.Integration.RuntimeTest do
  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.Runner.Result
  alias Alto.Session

  defmodule Tool do
    use Alto.Tool, name: :record, execution_mode: :exclusive, approval: :required
    def schema(_), do: %{parameters: %{type: "object", properties: %{value: %{}}}}

    def prepare(arguments, context, opts) do
      send(opts[:owner], {:prepared, arguments})
      block(opts, :prepare)

      case opts[:prepare_result] do
        nil -> {:ok, %{value: arguments["value"], cwd: context.cwd}, %{value: arguments["value"]}}
        result -> result
      end
    end

    def run(prepared, _context, opts) do
      block(opts, :tool)
      send(opts[:owner], {:executed, prepared.value})
      File.write!(Path.join(prepared.cwd, "effects"), inspect(prepared.value) <> "\n", [:append])
      Keyword.get(opts, :result, {:ok, prepared.value})
    end

    defp block(opts, phase) do
      if opts[:block] == phase do
        send(opts[:owner], {:waiting, phase, self()})
        receive do: (:release -> :ok)
      end
    end
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, sink, opts) do
      send(opts[:owner], {:request, request})

      if opts[:block] do
        send(opts[:owner], {:waiting, :provider, self()})
        receive do: (:release -> :ok)
      end

      if opts[:answer] || Enum.any?(request.messages, &(&1["role"] == "tool")) do
        sink.(Event.live(:model_delta, %{text: "done"}))
        {:ok, %{message: "done", tool_calls: [], usage: %{input_tokens: 5, output_tokens: 2}}}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [
             %{id: "call", name: "record", arguments_json: ~s({"value":"approved"})}
           ],
           usage: %{input_tokens: 3, output_tokens: 1}
         }}
      end
    end
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: cwd} do
    %{
      cwd: cwd,
      options: [
        cwd: cwd,
        tools: [{Tool, owner: self()}],
        provider: {Provider, owner: self()},
        approval: :approve
      ]
    }
  end

  test "model, prepared tool, middleware and saved follow-up retain their own identities", c do
    owner = self()

    hook = fn event, _ ->
      record =
        {:invoke_tool, %{id: "hook", name: "record", arguments: %{"value" => {:native, 7}}}}

      if event.data.outcome == :tools_completed,
        do: [{:invoke_tool, %{id: "missing-hook", name: "missing", arguments: %{}}}, record],
        else: [record]
    end

    trace = fn label ->
      fn event, _, next ->
        if event.type == :model_completed, do: send(owner, {:middleware, label, :before})
        result = next.(event)
        if event.type == :model_completed, do: send(owner, {:middleware, label, :after})
        result
      end
    end

    loop =
      Alto.default_loop(
        context: Alto.Context.Window.new(max_tokens: 50_000, reserve_output: 100),
        middleware: Enum.map([:first, :second], trace)
      )
      |> Alto.Loop.after_event(:step_settled, hook)

    approval = fn request, _ ->
      send(owner, {:approval, request})
      :approve
    end

    opts =
      Keyword.merge(c.options, loop: loop, approval: approval, session: :new, session_dir: c.cwd)

    assert %Result{status: :ok, output: "done", persistence: :ok} =
             result = Alto.run("start", opts)

    assert_receive {:approval,
                    %{arguments: %{"value" => "approved"}, details: %{value: "approved"}}}

    assert_receive {:executed, "approved"}
    assert_receive {:executed, {:native, 7}}
    assert_receive {:executed, {:native, 7}}
    refute_received {:executed, _}
    assert_receive {:request, _}
    assert_receive {:request, request}
    assert request.options["max_tokens"] == 100

    for expected <- [first: :before, second: :before, second: :after, first: :after] do
      assert_receive {:middleware, label, phase}
      assert {label, phase} == expected
    end

    assert Enum.any?(request.messages, &(&1["role"] == "tool" and &1["tool_call_id"] == "call"))
    refute Enum.any?(request.messages, &(&1["role"] == "tool" and &1["tool_call_id"] == "hook"))

    assert Enum.any?(
             request.messages,
             &(&1["role"] == "user" and &1["content"] =~ "alto_native_tool_result")
           )

    assert result.usage.input_tokens == 8
    assert result.usage.output_tokens == 3

    assert {:ok, %{"messages" => messages}} =
             Session.transcript(result.session_id, session_dir: c.cwd)

    assert messages == result.messages

    assert %Result{status: :ok, session_id: id, output: "done"} =
             resumed =
             Alto.resume(
               result.session_id,
               "follow-up",
               Keyword.put(c.options, :session_dir, c.cwd)
             )

    assert id == result.session_id
    assert resumed.run_id != result.run_id
    assert Enum.any?(resumed.messages, &(&1["content"] == "follow-up"))
    refute_received {:executed, _}
  end

  test "providerless rules compose native values, approvals and configured capabilities", c do
    loop =
      Alto.rule_loop(
        steps: [
          "record",
          %{tool: "record", arguments: fn _, [first] -> %{"value" => {:next, first}} end}
        ]
      )

    opts = Keyword.merge(c.options, provider: nil, loop: loop)

    assert %Result{status: :ok, output: [7, {:next, 7}], model_requests: 0} =
             Alto.run(%{"value" => 7}, opts)

    assert_receive {:executed, 7}
    assert_receive {:executed, {:next, 7}}
    refute_received {:request, _}
    before = File.read!(Path.join(c.cwd, "effects"))

    assert %Result{status: :error} =
             Alto.run(%{"value" => "denied"}, Keyword.put(opts, :approval, {:deny, :operator}))

    assert File.read!(Path.join(c.cwd, "effects")) == before
    refute_received {:executed, "denied"}
  end

  test "cancellation stops the current participant at every dispatch boundary", c do
    owner = self()

    for phase <- [:provider, :prepare, :approval, :tool] do
      approval = fn _, _ ->
        if phase == :approval do
          send(owner, {:waiting, :approval, self()})
          receive do: (:release -> :ok)
        end

        :approve
      end

      opts =
        Keyword.merge(c.options,
          provider: {Provider, owner: owner, block: phase == :provider},
          tools: [{Tool, owner: owner, block: phase}],
          approval: approval
        )

      assert {:ok, handle} = Alto.start("cancel", opts)
      assert_receive {:waiting, ^phase, participant}, 2_000
      monitor = Process.monitor(participant)
      assert {:error, :await_timeout} = Alto.await(handle, 0)
      assert :ok = Alto.cancel(handle, :operator)
      assert %Result{status: :cancelled, reason: :operator} = Alto.await(handle, 2_000)
      assert_receive {:DOWN, ^monitor, :process, ^participant, _}, 2_000
      refute_received {:executed, _}
      refute File.exists?(Path.join(c.cwd, "effects"))
    end
  end

  @tag capture_log: true
  test "invalid preparation and timed-out callbacks cannot reach approval or execution", c do
    owner = self()

    approval = fn _, _ ->
      send(owner, :approved)
      :approve
    end

    for result <- [
          {:error, :refused},
          :malformed,
          {:ok, %{}, "invalid details"},
          {:ok, %{}, %{large: String.duplicate("secret", 1000)}}
        ] do
      opts =
        Keyword.merge(c.options,
          tools: [{Tool, owner: owner, prepare_result: result}],
          approval: approval,
          max_approval_details_bytes: 128
        )

      assert %Result{status: :ok, output: "done"} = run = Alto.run("prepare", opts)
      assert Enum.any?(run.events, &(&1.type == :tool_failed))
      refute_received :approved
      refute_received {:executed, _}
    end

    opts =
      Keyword.merge(c.options,
        tools: [{Tool, owner: owner, block: :prepare}],
        approval: approval,
        tool_timeout: 100
      )

    assert %Result{status: :ok, output: "done"} = Alto.run("timeout", opts)
    assert_receive {:waiting, :prepare, participant}
    refute Process.alive?(participant)
    refute_received :approved
    refute File.exists?(Path.join(c.cwd, "effects"))
  end

  test "limits and unsupported capabilities reject work before paid or mutating dispatch", c do
    for {options, reason} <- [
          {[max_transcript_bytes: 1], {:transcript_limit, 1}},
          {[loop: Alto.chat_loop(context: Alto.Context.Window.new(max_tokens: 1))],
           {:context_limit, :any}},
          {[model_tools: ["missing"]], {:unknown_model_tool, "missing"}},
          {[session: "../escape"], {:invalid_session_id, "../escape"}},
          {[max_steps: 0], {:invalid_option, :max_steps, 0}}
        ] do
      assert %Result{status: :error} =
               result = Alto.run("reject", Keyword.merge(c.options, options))

      if reason == {:context_limit, :any},
        do: assert(match?({:context_limit, _}, result.reason)),
        else: assert(result.reason == reason)

      refute_received {:request, _}
      refute_received {:executed, _}
    end

    for {option, reason} <- [
          max_steps: :model_step_limit,
          max_model_requests: :model_request_limit
        ] do
      assert %Result{status: :error, reason: {^reason, 1}} =
               Alto.run("one step", Keyword.put(c.options, option, 1))

      assert_receive {:request, _}
      assert_receive {:executed, "approved"}
      refute_received {:request, _}
    end
  end

  test "oversized success, failures and malformed results remain bounded without replay", c do
    large = String.duplicate("private", 20_000)

    for returned <- [
          {:ok, large},
          {:ok, %{nested: [large]}},
          {:unexpected, large},
          {:error, large}
        ],
        mode <- [:native, :model] do
      opts =
        Keyword.merge(c.options,
          tools: [{Tool, owner: self(), result: returned}],
          max_tool_result_bytes: 128,
          session: :new,
          session_dir: c.cwd
        )

      opts =
        if mode == :native,
          do: Keyword.merge(opts, provider: nil, loop: Alto.rule_loop(steps: ["record"])),
          else: opts

      result = Alto.run(%{"value" => 7}, opts)
      assert_receive {:executed, _}
      refute_received {:executed, _}
      assert Enum.any?(result.events, &(&1.type == :tool_failed))
      refute inspect(result.events) =~ String.duplicate("private", 10)
      refute inspect(result.messages) =~ String.duplicate("private", 10)
      assert {:ok, records} = Session.read(result.session_id, session_dir: c.cwd)
      refute inspect(records) =~ String.duplicate("private", 10)
    end
  end

  test "chat rejects tool calls and model-less runs reject model-only configuration", c do
    assert %Result{status: :error, reason: {:tools_not_supported, ["call"]}} =
             Alto.run("chat", Keyword.put(c.options, :loop, Alto.chat_loop()))

    refute_received {:executed, _}
    assert %Result{status: :error, reason: :provider_required} = Alto.run("missing provider")

    assert %Result{status: :error, reason: :prompt_options_require_provider} =
             Alto.run(%{},
               provider: nil,
               prompt: "model instructions",
               loop: Alto.rule_loop(steps: ["record"])
             )
  end
end
