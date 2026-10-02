defmodule Alto.Contrib.CacheWarmerTest do
  use ExUnit.Case, async: true
  alias Alto.Contrib.CacheWarmer
  alias Alto.Contrib.Providers.Anthropic

  defmodule Adapter do
    def run(req) do
      owner = Req.Request.get_private(req, :test_owner)
      body = JSON.decode!(req.body)
      send(owner, {:wire, body})

      if body["max_tokens"] == 0 and Req.Request.get_private(req, :test_stall) do
        send(owner, {:warm_transport, self()})

        receive do
          :finish_warm -> :ok
        end
      end

      tool_result? =
        Enum.any?(body["messages"], fn message ->
          Enum.any?(message["content"], &(&1["type"] == "tool_result"))
        end)

      content =
        cond do
          body["max_tokens"] == 0 ->
            []

          Req.Request.get_private(req, :test_tool) and not tool_result? ->
            [%{"type" => "tool_use", "id" => "wait-1", "name" => "wait", "input" => %{}}]

          true ->
            [%{"type" => "text", "text" => "answer"}]
        end

      response = %{
        "content" => content,
        "stop_reason" => if(body["max_tokens"] == 0, do: "max_tokens", else: "end_turn"),
        "usage" => %{
          "input_tokens" => 5,
          "cache_read_input_tokens" => 2048,
          "output_tokens" => if(body["max_tokens"] == 0, do: 0, else: 1)
        }
      }

      response = Req.Request.get_private(req, :test_response, response)

      {:cont, result} =
        req.into.({:data, JSON.encode!(response)}, {req, Req.Response.new(status: 200)})

      result
    end
  end

  defp provider(owner, tool? \\ false, stall? \\ false) do
    [
      model: "test-model",
      api_key: "test-key",
      req_options: [
        adapter: Adapter,
        plugins: [
          fn request ->
            request
            |> Req.Request.put_private(:test_owner, owner)
            |> Req.Request.put_private(:test_tool, tool?)
            |> Req.Request.put_private(:test_stall, stall?)
          end
        ]
      ]
    ]
  end

  defmodule WaitingTool do
    use Alto.Tool, name: :wait, execution_mode: :parallel, approval: :never
    def schema(_), do: Alto.Tool.object_schema("wait", %{})

    def run(_, _, opts) do
      send(opts[:owner], {:waiting_tool, self()})

      receive do
        :finish -> {:ok, "done"}
      end
    end
  end

  defp request do
    %{
      run_id: "root",
      messages: [
        %{"role" => "system", "content" => "stable policy"},
        %{"role" => "user", "content" => "Do the job"}
      ],
      tools: [
        %{
          "type" => "function",
          "function" => %{
            "name" => "job",
            "description" => "Do work",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        }
      ],
      options: %{"tool_choice" => %{"type" => "auto"}, "temperature" => 0.2}
    }
  end

  test "zero-token request preserves the exact native cache prefix and uses bounded HTTP transport" do
    opts = provider(self())
    assert {:ok, _} = Anthropic.stream(request(), fn _ -> :ok end, opts)
    assert_receive {:wire, original}
    assert {:ok, plan} = Anthropic.cache_warm_plan(request(), opts)
    assert plan.ttl_ms == 300_000

    assert {:ok, %{cache_hit: true, output: false, usage: usage}} =
             Anthropic.warm_cache(plan, 500)

    assert usage.cached_input_tokens == 2048
    assert usage.input_tokens == 2053
    assert usage.output_tokens == 0
    assert_receive {:wire, warmed}
    assert warmed["max_tokens"] == 0
    assert warmed["stream"] == false

    assert Map.drop(warmed, ["max_tokens", "stream"]) ==
             Map.drop(original, ["max_tokens", "stream"])

    assert warmed["tool_choice"] == %{"type" => "auto"}
    refute_receive {:wire, _}, 10
  end

  test "one-hour cache control is respected and unsafe replay options fail closed" do
    opts = provider(self())
    req = request()

    assert {:ok, %{ttl_ms: 3_600_000}} =
             Anthropic.cache_warm_plan(
               put_in(req.options["cache_control"], %{"type" => "ephemeral", "ttl" => "1h"}),
               opts
             )

    for extra <- [
          %{"thinking" => %{"type" => "enabled", "budget_tokens" => 1024}},
          %{"thinking" => %{"type" => "adaptive"}},
          %{"output_config" => %{"format" => %{"type" => "json_schema"}}},
          %{"tool_choice" => %{"type" => "any"}},
          %{"tool_choice" => %{"type" => "tool", "name" => "job"}},
          %{"cache_control" => %{"type" => "ephemeral", "ttl" => "unknown"}}
        ] do
      assert {:error, :cache_warming_unsupported_request} =
               Anthropic.cache_warm_plan(%{req | options: Map.merge(req.options, extra)}, opts)
    end

    assert {:error, _} = Anthropic.cache_warm_plan(req, Keyword.put(opts, :prompt_cache, false))

    assert {:error, _} =
             Anthropic.cache_warm_plan(
               req,
               Keyword.put(opts, :thinking, %{"type" => "enabled", "budget_tokens" => 1024})
             )

    refute_receive {:wire, _}, 10
  end

  test "zero-token decoder rejects content, tools, billed output and malformed responses" do
    for response <- [
          %{
            "content" => [%{"type" => "text", "text" => "unexpected"}],
            "stop_reason" => "max_tokens",
            "usage" => %{"output_tokens" => 0}
          },
          %{
            "content" => [%{"type" => "tool_use", "id" => "x", "name" => "wait", "input" => %{}}],
            "stop_reason" => "max_tokens",
            "usage" => %{"output_tokens" => 0}
          },
          %{"content" => [], "stop_reason" => "max_tokens", "usage" => %{"output_tokens" => 1}},
          %{"content" => [], "stop_reason" => "max_tokens"},
          %{"content" => [], "stop_reason" => "end_turn", "usage" => %{"output_tokens" => 0}},
          "malformed"
        ] do
      opts =
        Keyword.update!(provider(self()), :req_options, fn options ->
          Keyword.update!(options, :plugins, fn plugins ->
            plugins ++ [fn req -> Req.Request.put_private(req, :test_response, response) end]
          end)
        end)

      assert {:ok, plan} = Anthropic.cache_warm_plan(request(), opts)

      if is_map(response) and is_map(response["usage"]) do
        assert {:error, {:invalid_cache_warm_response, usage}} = Anthropic.warm_cache(plan, 500)
        assert usage.output_tokens == response["usage"]["output_tokens"]
      else
        assert {:error, :invalid_cache_warm_response} = Anthropic.warm_cache(plan, 500)
      end
    end
  end

  test "nested atom option keys receive the same wire eligibility checks" do
    opts = provider(self())

    for options <- [
          %{output_config: %{format: %{type: "json_schema"}}},
          %{thinking: %{type: "enabled", budget_tokens: 1024}},
          %{tool_choice: %{type: "any"}}
        ] do
      assert {:error, :cache_warming_unsupported_request} =
               Anthropic.cache_warm_plan(%{request() | options: options}, opts)
    end

    assert {:ok, %{ttl_ms: 3_600_000}} =
             Anthropic.cache_warm_plan(
               %{request() | options: %{cache_control: %{type: "ephemeral", ttl: "1h"}}},
               opts
             )

    refute_receive {:wire, _}, 10
  end

  test "facade returns a regular handle and leaves model accounting and transcript alone" do
    owner = self()

    opts = [
      provider: {Anthropic, provider(owner)},
      tools: [],
      event_sink: &send(owner, {:event, &1})
    ]

    assert {:ok, %Alto.Runner.Handle{} = handle} = CacheWarmer.start("answer", opts)
    result = Alto.await(handle)
    assert result.status == :ok
    assert result.output == "answer"
    assert result.model_requests == 1
    assert result.usage.requests == 1
    assert_receive {:wire, %{"max_tokens" => max_tokens}}
    assert max_tokens > 0
    assert :ok = Alto.Runner.release(handle)
    refute_receive {:event, %{type: :cache_warm_started}}, 10
    assert %{status: :ok, output: "answer"} = CacheWarmer.run("answer", opts)
  end

  test "an active tool receives a zero-output refresh without dispatching another tool or consuming core steps" do
    owner = self()

    opts = [
      provider: {Anthropic, provider(owner, true)},
      tools: [{WaitingTool, owner: owner}],
      max_model_requests: 2,
      event_sink: &send(owner, {:event, &1})
    ]

    assert {:ok, handle} =
             CacheWarmer.start("wait then answer", opts,
               refresh_margin_ms: 299_900,
               max_requests: 1
             )

    assert_receive {:waiting_tool, tool}, 1_000
    assert_receive {:wire, %{"max_tokens" => 0}}, 1_000

    assert_receive {:event,
                    %{
                      type: :cache_warm_finished,
                      data: %{cache_hit: true, usage: %{output_tokens: 0}}
                    }},
                   1_000

    refute_receive {:waiting_tool, _}, 10
    send(tool, :finish)
    result = Alto.await(handle)
    assert result.status == :ok
    assert result.output == "answer"
    assert result.model_requests == 2
    assert result.usage.requests == 2
    assert :ok = Alto.Runner.release(handle)
    refute_receive {:wire, %{"max_tokens" => 0}}, 20
  end

  test "cancelling the async façade kills an in-flight warming transport" do
    owner = self()

    opts = [
      provider: {Anthropic, provider(owner, true, true)},
      tools: [{WaitingTool, owner: owner}],
      event_sink: &send(owner, {:event, &1})
    ]

    assert {:ok, handle} = CacheWarmer.start("wait", opts, refresh_margin_ms: 299_900)
    assert_receive {:waiting_tool, _}, 1_000
    assert_receive {:warm_transport, transport}, 1_000
    monitor = Process.monitor(transport)
    assert :ok = Alto.cancel(handle)
    result = Alto.await(handle)
    assert result.status == :cancelled
    assert_receive {:DOWN, ^monitor, :process, ^transport, _}, 1_000
    assert :ok = Alto.Runner.release(handle)
  end

  test "synchronous caller death cancels the run and warmer" do
    owner = self()

    caller =
      spawn(fn ->
        CacheWarmer.run(
          "wait",
          [
            provider: {Anthropic, provider(owner, true, true)},
            tools: [{WaitingTool, owner: owner}]
          ],
          refresh_margin_ms: 299_900
        )
      end)

    assert_receive {:waiting_tool, tool}, 1_000
    assert_receive {:warm_transport, transport}, 1_000
    tool_ref = Process.monitor(tool)
    transport_ref = Process.monitor(transport)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^tool_ref, :process, ^tool, _}, 1_000
    assert_receive {:DOWN, ^transport_ref, :process, ^transport, _}, 1_000
  end

  test "unsupported providers, invalid budgets and invalid owners do not start traffic" do
    assert {:error, :cache_warming_requires_native_anthropic} = CacheWarmer.start("x", [])

    assert {:error, :cache_warming_requires_native_anthropic} =
             CacheWarmer.start("x", provider: Alto.Contrib.Providers.OpenAICompatible)

    assert {:error, %NimbleOptions.ValidationError{}} =
             CacheWarmer.start("x", [provider: {Anthropic, provider(self())}], max_requests: 0)

    assert {:error, :invalid_owner} =
             CacheWarmer.start("x", provider: {Anthropic, provider(self())}, owner: :invalid)

    refute_receive {:wire, _}, 10
  end
end
