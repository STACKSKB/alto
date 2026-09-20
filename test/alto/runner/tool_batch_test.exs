defmodule Alto.Runner.ToolBatchTest do
  use ExUnit.Case, async: true

  defmodule Read do
    @behaviour Alto.Tool
    def name, do: :read
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :parallel
    def approval, do: :never

    def prepare(args, _context, opts) do
      send(opts[:test_pid], {:prepared, args["value"]})
      if args["reject"], do: {:error, :bad_input}, else: {:ok, args, %{}}
    end

    def run_prepared(args, _context, opts) do
      send(opts[:test_pid], {:started, args["value"], self()})

      if args["block"],
        do:
          (receive do
             :release -> :ok
           end)

      {:ok, args["value"]}
    end
  end

  defmodule Write do
    @behaviour Alto.Tool
    def name, do: :write
    def schema, do: Read.schema()
    def execution_mode, do: :exclusive
    def approval, do: :required

    def run(args, _context, opts) do
      send(opts[:test_pid], {:write, args["value"]})
      {:ok, :written}
    end
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _, opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        send(opts[:test_pid], {:history, request.messages})
        {:ok, %{message: "done", tool_calls: []}}
      else
        {:ok, %{message: nil, tool_calls: opts[:calls]}}
      end
    end
  end

  defp call(id, args, name \\ "read"),
    do: %{id: id, name: name, arguments_json: JSON.encode!(args)}

  defp options(calls, extra \\ []) do
    Keyword.merge(
      [
        loop: Alto.default_loop(tool_execution: {:parallel, 2}),
        tools: [{Read, test_pid: self()}, {Write, test_pid: self()}],
        provider: {Provider, calls: calls, test_pid: self()},
        approval: Alto.Approvals.DenyAll
      ],
      extra
    )
  end

  test "independent reads progress concurrently and history settles in source order" do
    {:ok, handle} =
      Alto.start(
        "read",
        options([
          call("a", %{value: "first", block: true}),
          call("b", %{value: "second"})
        ])
      )

    assert_receive {:started, "first", first}
    assert_receive {:started, "second", _}
    refute_receive {:history, _}, 30
    send(first, :release)
    assert {:ok, _} = Alto.await(handle)
    assert_receive {:history, history}

    assert Enum.filter(history, &(&1["role"] == "tool")) |> Enum.map(& &1["tool_call_id"]) == [
             "a",
             "b"
           ]

    assert_receive {:prepared, "first"}
    refute_receive {:prepared, "first"}, 10
  end

  test "preparation happens once and rejected preparation never executes" do
    assert {:ok, _} =
             Alto.run(
               "read",
               options([
                 call("a", %{value: "bad", reject: true}),
                 call("b", %{value: "good"})
               ])
             )

    assert_receive {:prepared, "bad"}
    assert_receive {:prepared, "good"}
    refute_receive {:prepared, _}, 20
    refute_receive {:started, "bad", _}, 20
    assert_receive {:started, "good", _}
  end

  test "exclusive approval-requiring calls are barriers and denial prevents invocation" do
    {:ok, handle} =
      Alto.start(
        "read",
        options([
          call("a", %{value: "first", block: true}),
          call("w", %{value: "mutation"}, "write"),
          call("b", %{value: "last"})
        ])
      )

    assert_receive {:started, "first", first}
    refute_receive {:started, "last", _}, 30
    send(first, :release)
    assert {:ok, result} = Alto.await(handle)
    assert_receive {:started, "last", _}
    refute_receive {:write, _}, 20
    assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.name == "write"))
  end

  test "concurrency limit prevents the next group from starting early" do
    calls = for i <- 1..3, do: call(to_string(i), %{value: i, block: true})
    {:ok, handle} = Alto.start("read", options(calls))
    assert_receive {:started, 1, one}
    assert_receive {:started, 2, two}
    refute_receive {:started, 3, _}, 30
    send(one, :release)
    send(two, :release)
    assert_receive {:started, 3, three}
    send(three, :release)
    assert {:ok, _} = Alto.await(handle)
  end

  test "cancellation terminates all dispatched workers and retains unknown outcomes" do
    {:ok, handle} =
      Alto.start(
        "read",
        options([
          call("a", %{value: "a", block: true}),
          call("b", %{value: "b", block: true})
        ])
      )

    assert_receive {:started, "a", a}
    assert_receive {:started, "b", b}
    ma = Process.monitor(a)
    mb = Process.monitor(b)
    assert :ok = Alto.cancel(handle)
    assert {:error, {:cancelled, :user}, result} = Alto.await(handle)
    assert_receive {:DOWN, ^ma, :process, ^a, _}
    assert_receive {:DOWN, ^mb, :process, ^b, _}
    assert result.verdict == :unknown
    assert Enum.count(result.events, &(&1.type == :tool_failed)) == 2
  end

  test "effect admission uses the shared cap before dispatch" do
    assert {:error, _, _} =
             Alto.run(
               "read",
               options(
                 [
                   call("a", %{value: 1}),
                   call("b", %{value: 2})
                 ],
                 max_effects: 2
               )
             )

    refute_receive {:started, _, _}, 20
  end

  test "ordinary default loop remains serial" do
    {:ok, handle} =
      Alto.start(
        "read",
        options(
          [
            call("a", %{value: 1, block: true}),
            call("b", %{value: 2})
          ],
          loop: Alto.default_loop()
        )
      )

    assert_receive {:started, 1, one}
    refute_receive {:started, 2, _}, 30
    send(one, :release)
    assert {:ok, _} = Alto.await(handle)
    assert_receive {:started, 2, _}
  end

  test "hard coordinator death terminates every batch worker" do
    {:ok, handle} =
      Alto.start(
        "read",
        options([
          call("a", %{value: 1, block: true}),
          call("b", %{value: 2, block: true})
        ])
      )

    assert_receive {:started, 1, one}
    assert_receive {:started, 2, two}
    m1 = Process.monitor(one)
    m2 = Process.monitor(two)
    assert {:error, _, result} = Alto.Runner.terminate(handle)
    assert result.verdict == :unknown
    assert_receive {:DOWN, ^m1, :process, ^one, _}
    assert_receive {:DOWN, ^m2, :process, ^two, _}
  end

  test "approval checkpoint retains later parallel groups without replaying prior reads" do
    opts =
      options(
        [
          call("a", %{value: "before"}),
          call("w", %{value: "write"}, "write"),
          call("b", %{value: "after"})
        ],
        approval: Alto.Approvals.Checkpoint,
        checkpoint_version: "batch-v1"
      )

    assert {:error, :approval_suspended, paused} = Alto.run("read", opts)
    assert_receive {:started, "before", _}
    refute_receive {:started, "after", _}, 20

    assert {:ok, result} =
             Alto.run("read", Keyword.put(opts, :checkpoint, {paused.checkpoint, :approve}))

    assert result.output == "done"
    assert_receive {:write, "write"}
    assert_receive {:started, "after", _}
    refute_receive {:started, "before", _}, 20
  end

  test "blocked worker times out while sibling result is retained" do
    opts =
      options(
        [
          call("a", %{value: "blocked", block: true}),
          call("b", %{value: "done"})
        ],
        tool_timeout: 80
      )

    assert {:ok, result} = Alto.run("read", opts)
    assert result.verdict == :unknown
    assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.call_id == "a"))
    assert Enum.any?(result.events, &(&1.type == :tool_completed and &1.data.call_id == "b"))
  end

  test "oversize parallel results use the same uncertain classification as serial dispatch" do
    huge = String.duplicate("x", 10_000)

    assert {:ok, result} =
             Alto.run(
               "read",
               options([call("big", %{value: huge})], max_tool_result_bytes: 100)
             )

    assert result.verdict == :unknown

    assert Enum.any?(result.events, fn
             %{type: :tool_failed, data: %{call_id: "big", outcome: :unknown, error: error}} ->
               match?({:tool_result_too_large, _}, error)

             _ ->
               false
           end)

    refute inspect(result.events) =~ huge
  end
end
