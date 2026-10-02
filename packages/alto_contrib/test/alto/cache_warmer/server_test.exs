defmodule Alto.Contrib.CacheWarmer.ServerTest do
  use ExUnit.Case, async: true
  alias Alto.Contrib.CacheWarmer.Server
  alias Alto.Event

  setup do
    clock = :atomics.new(1, [])
    owner = self()

    args = %{
      run_id: "root",
      owner: owner,
      sink: &send(owner, {:event, &1}),
      max_requests: 2,
      max_duration_ms: 50_000,
      request_timeout_ms: 500,
      refresh_margin_ms: 1_000,
      max_prompt_bytes: 100,
      clock: fn -> :atomics.get(clock, 1) end,
      plan: fn request -> {:ok, %{ttl_ms: 10_000, bytes: 50, request: request}} end,
      refresh: fn plan, timeout ->
        send(owner, {:refresh, self(), plan.request, timeout})

        receive do
          {:reply, result} -> result
        end
      end
    }

    %{clock: clock, args: args}
  end

  defp start(args) do
    {:ok, pid} = Server.start(args)
    on_exit(fn -> Server.stop(pid) end)
    pid
  end

  defp event(pid, type, data \\ %{}), do: Server.event(pid, Event.live(type, data))

  defp begin(pid, request \\ %{run_id: "root", messages: ["exact"]}) do
    event(pid, :model_started)
    Server.request(pid, request)
    event(pid, :model_completed)
    event(pid, :tool_started, %{operation_id: "one"})
  end

  defp advance(pid, clock, now) do
    :atomics.put(clock, 1, now)
    Server.pulse(pid)
  end

  defp reply(pid, hit \\ true) do
    send(
      pid,
      {:reply,
       {:ok,
        %{
          usage: %{input_tokens: 100, cached_input_tokens: if(hit, do: 100, else: 0)},
          cache_hit: hit,
          output: false
        }}}
    )
  end

  test "refreshes the root's successful exact request only during tools, with a finite total budget",
       ctx do
    pid = start(ctx.args)
    begin(pid)
    advance(pid, ctx.clock, 8_999)
    refute_receive {:refresh, _, _, _}, 10
    # Even a child sharing the conversation and nested events cannot replace it.
    Server.request(pid, %{run_id: "child", messages: ["child"]})
    event(pid, :subagent_progress, %{event: Event.live(:model_started)})
    advance(pid, ctx.clock, 9_000)
    assert_receive {:refresh, worker, %{run_id: "root", messages: ["exact"]}, 500}
    advance(pid, ctx.clock, 9_001)
    refute_receive {:refresh, _, _, _}, 10
    reply(worker)
    assert_receive {:event, %{type: :cache_warm_finished, data: %{cache_hit: true}}}
    advance(pid, ctx.clock, 18_000)
    assert_receive {:refresh, worker, _, _}
    reply(worker)
    assert_receive {:event, %{type: :cache_warm_finished}}
    advance(pid, ctx.clock, 27_000)
    refute_receive {:refresh, _, _, _}, 10
  end

  test "suppresses unsupported, auxiliary, oversized and unsuccessful model attempts", ctx do
    for request <- [%{}, %{run_id: "child"}] do
      pid = start(ctx.args)
      begin(pid, request)
      advance(pid, ctx.clock, 9_000)
      refute_receive {:refresh, _, _, _}, 10
      Server.stop(pid)
      :atomics.put(ctx.clock, 1, 0)
    end

    pid = start(%{ctx.args | max_prompt_bytes: 1})
    begin(pid)
    advance(pid, ctx.clock, 9_000)
    refute_receive {:refresh, _, _, _}, 10
    :atomics.put(ctx.clock, 1, 0)
    pid = start(ctx.args)
    event(pid, :model_started)
    Server.request(pid, %{run_id: "root"})
    event(pid, :tool_started, %{operation_id: "one"})
    advance(pid, ctx.clock, 9_000)
    refute_receive {:refresh, _, _, _}, 10
  end

  test "stops a candidate on miss or error and reports usage separately", ctx do
    for outcome <- [:miss, :error] do
      :atomics.put(ctx.clock, 1, 0)
      pid = start(ctx.args)
      begin(pid)
      advance(pid, ctx.clock, 9_000)
      assert_receive {:refresh, worker, _, _}

      if outcome == :miss,
        do: reply(worker, false),
        else: send(worker, {:reply, {:error, :offline}})

      assert_receive {:event, %{type: :cache_warm_finished, data: data}}

      if outcome == :miss,
        do: assert(data.usage.input_tokens == 100),
        else: assert(data.usage_unknown)

      advance(pid, ctx.clock, 18_000)
      refute_receive {:refresh, _, _, _}, 10
      Server.stop(pid)
    end
  end

  test "does not refresh after expiry or the fixed horizon", ctx do
    for now <- [10_000, 50_000] do
      :atomics.put(ctx.clock, 1, 0)
      pid = start(ctx.args)
      begin(pid)
      advance(pid, ctx.clock, now)
      refute_receive {:refresh, _, _, _}, 10
      Server.stop(pid)
    end
  end

  test "terminates in-flight transport on last tool, next model, cancellation and run completion",
       ctx do
    for signal <- [:tool_completed, :model_started, :run_cancelled, :result] do
      :atomics.put(ctx.clock, 1, 0)
      pid = start(ctx.args)
      begin(pid)
      advance(pid, ctx.clock, 9_000)
      assert_receive {:refresh, worker, _, _}
      ref = Process.monitor(worker)

      if signal == :result,
        do: send(pid, {:alto_runner_result, make_ref(), :done}),
        else: event(pid, signal, %{operation_id: "one"})

      assert_receive {:DOWN, ^ref, :process, ^worker, _}
      assert_receive {:event, %{type: :cache_warm_finished, data: %{usage_unknown: true}}}
      Server.stop(pid)
    end
  end

  test "owner death and timeout cannot leave a refresh running", ctx do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    pid = start(%{ctx.args | owner: owner})
    begin(pid)
    advance(pid, ctx.clock, 9_000)
    assert_receive {:refresh, worker, _, _}
    ref = Process.monitor(worker)
    server_ref = Process.monitor(pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^server_ref, :process, ^pid, _}
    assert_receive {:DOWN, ^ref, :process, ^worker, _}

    :atomics.put(ctx.clock, 1, 0)
    pid = start(%{ctx.args | request_timeout_ms: 20})
    begin(pid)
    advance(pid, ctx.clock, 9_000)
    assert_receive {:refresh, worker, _, 20}
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 500
    assert_receive {:event, %{type: :cache_warm_finished, data: %{usage_unknown: true}}}
  end

  test "status and failures do not disclose prompts or credentials", ctx do
    secret = "private-api-key-and-prompt"

    args = %{
      ctx.args
      | plan: fn request ->
          {:ok, %{ttl_ms: 10_000, bytes: 50, request: request, api_key: secret}}
        end
    }

    pid = start(args)
    begin(pid, %{run_id: "root", messages: [secret]})
    refute inspect(:sys.get_status(pid), limit: :infinity) =~ secret

    formatted =
      Server.format_status(%{
        state: :sys.get_state(pid),
        message: secret,
        reason: {:failed, secret},
        log: [secret]
      })

    refute inspect(formatted, limit: :infinity) =~ secret
    Server.stop(pid)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pid = start(%{ctx.args | plan: fn _ -> raise secret end})
        begin(pid)
        assert Process.alive?(pid)
        advance(pid, ctx.clock, 9_000)
        refute_receive {:refresh, _, _, _}, 10
        Server.stop(pid)
      end)

    refute log =~ secret
  end

  test "a hanging host observer cannot block owner-death cleanup", ctx do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    test = self()

    sink = fn event ->
      if event.type == :cache_warm_started do
        send(test, :sink_blocked)

        receive do
          :never -> :ok
        end
      end
    end

    pid = start(%{ctx.args | owner: owner, sink: sink})
    begin(pid)
    pulse = Task.async(fn -> advance(pid, ctx.clock, 9_000) end)
    assert_receive :sink_blocked
    assert_receive {:refresh, worker, _, _}
    worker_ref = Process.monitor(worker)
    server_ref = Process.monitor(pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^server_ref, :process, ^pid, _}, 500
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 500
    Task.await(pulse)
  end
end
