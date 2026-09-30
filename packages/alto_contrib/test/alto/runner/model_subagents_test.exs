defmodule Alto.Runner.ModelSubagentsTest do
  use ExUnit.Case, async: true

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:owner], {:request, request})

      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        {:ok, %{message: "done", tool_calls: []}}
      else
        {:ok, %{message: nil, tool_calls: Keyword.fetch!(opts, :calls)}}
      end
    end
  end

  defmodule Child do
    @behaviour Alto.Provider
    def describe(_), do: %{}
    def list_models(_), do: {:ok, [%{id: "model-a"}, %{id: "model-b"}]}

    def stream(request, _sink, opts) do
      send(opts[:owner], {:child, request})
      send(opts[:owner], {:selected_model, opts[:model]})
      if opts[:api_key], do: send(opts[:owner], {:credential, opts[:api_key]})

      if opts[:model] == opts[:fail_model] do
        {:error, opts[:fail_reason]}
      else
        {:ok,
         %{
           message: opts[:answer] || "child done",
           tool_calls: [],
           usage: %{input_tokens: 4, output_tokens: 2}
         }}
      end
    end
  end

  defmodule CurrentProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}
    def list_models(opts), do: Child.list_models(opts)

    def stream(request, sink, opts) do
      if opts[:model] == "child-model",
        do: Child.stream(request, sink, opts),
        else: Provider.stream(request, sink, opts)
    end
  end

  defmodule Block do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_request, _sink, opts) do
      send(opts[:owner], {:blocking, self()})
      receive do: (:never -> :ok)
    end
  end

  defp call(id, name, arguments),
    do: %{id: id, name: name, arguments_json: JSON.encode!(arguments)}

  defp task(id \\ "child", agent \\ "worker"),
    do: %{"id" => id, "backend" => agent, "model" => "model-a", "task" => "Investigate this"}

  defp options(calls, overrides \\ []) do
    Keyword.merge(
      [
        provider: {Provider, owner: self(), calls: calls},
        tools: Alto.Contrib.Tools.agents(),
        provider_profiles: [
          %Alto.Contrib.ProviderProfile{id: "worker", provider: {Child, owner: self()}}
        ],
        approval: :approve,
        loop:
          Alto.default_loop(
            tool_execution: {:parallel, 4},
            subagents: Alto.Subagents.bounded(max_depth: 1, max_children: 4, max_concurrency: 2)
          )
      ],
      overrides
    )
  end

  test "cancelling a dispatched spawn records an unknown outcome and remains resumable" do
    dir = Path.join(System.tmp_dir!(), "alto-cancel-spawn-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]

    opts =
      options(calls,
        session: :new,
        session_dir: dir,
        session_history: :settled,
        provider_profiles: [
          %Alto.Contrib.ProviderProfile{id: "worker", provider: {Block, owner: self()}}
        ]
      )

    {:ok, handle} = Alto.Contrib.start("delegate", opts)
    assert_receive {:blocking, _}, 5_000
    :ok = Alto.cancel(handle, :user)
    result = Alto.await(handle, 5_000)
    assert result.status == :cancelled
    assert result.persistence == :ok
    assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.outcome == :unknown))
    assert {:ok, resume} = Alto.Session.resume_options(result.session_id, session_dir: dir)

    continued =
      Alto.Contrib.run(
        "continue without repeating the cancelled work",
        Keyword.merge(opts, resume)
      )

    assert continued.status == :ok

    assert Enum.any?(continued.messages, fn message ->
             message["role"] == "tool" and message["tool_call_id"] == "spawn" and
               String.contains?(message["content"], "cancelled")
           end)

    refute_receive {:blocking, _}, 20
  end

  test "child lifecycle and model activity have stable separate identities" do
    owner = self()
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]

    result =
      Alto.Contrib.run(
        "delegate",
        options(calls, event_sink: fn event -> send(owner, {:child_event, event}) end)
      )

    assert result.status == :ok

    assert_receive {:child_event,
                    %{type: :subagent_status, data: %{agent_id: id, status: :starting}}}

    assert_receive {:child_event,
                    %{
                      type: :subagent_progress,
                      data: %{agent_id: ^id, event: %{type: :model_started}}
                    }}

    assert_receive {:child_event,
                    %{
                      type: :subagent_status,
                      data: %{agent_id: ^id, status: :completed, result: %{status: :ok}}
                    }}
  end

  test "Codex rule children do not inherit a provider-only prompt" do
    calls = [call("spawn", "spawn_agents", %{"agents" => [task("child", "codex")]})]

    opts =
      options(calls,
        prompt: &Alto.Contrib.Prompts.Coding.build/1,
        tools:
          Alto.Contrib.Tools.agents() ++
            [{Alto.Contrib.Tools.CodexAgent, command: "/nonexistent/alto-test-codex"}]
      )

    result = Alto.Contrib.run("delegate", opts)
    reply = Enum.find(result.messages, &(&1["tool_call_id"] == "spawn"))
    assert reply
    refute reply["content"] =~ "prompt_options_require_provider"
    assert reply["content"] =~ "error"
  end

  test "mixed discovery and delegation settle correlated tool calls and merge child usage" do
    calls = [
      call("list", "list_agent_models", %{}),
      call("spawn", "spawn_agents", %{"agents" => [task()]})
    ]

    assert %Alto.Runner.Result{status: :ok} =
             result = Alto.Contrib.run("delegate", options(calls))

    assert result.output == "done"
    assert result.usage.total_tokens == 6
    replies = Enum.filter(result.messages, &(&1["role"] == "tool"))
    assert Enum.map(replies, & &1["tool_call_id"]) == ["list", "spawn"]
    discovery = replies |> hd() |> Map.fetch!("content") |> JSON.decode!()

    assert discovery["models"] == [
             %{"backend" => "worker", "model" => "model-a", "name" => "model-a"},
             %{"backend" => "worker", "model" => "model-b", "name" => "model-b"}
           ]

    assert [%{"id" => "child", "status" => "ok", "output" => "child done"}] =
             JSON.decode!(List.last(replies)["content"])["results"]

    assert_receive {:child, request}
    assert Enum.any?(request.messages, &(&1["content"] == "Investigate this"))
  end

  test "catalog failures retain successful models and backend order" do
    profiles =
      for {id, provider} <- [
            {"z-unavailable", Provider},
            {"worker", Child},
            {"a-unavailable", Provider}
          ],
          do: %Alto.Contrib.ProviderProfile{id: id, provider: {provider, []}}

    assert %Alto.Runner.Result{status: :ok} =
             result =
             Alto.Contrib.run(
               "discover",
               options([call("list", "list_agent_models", %{})], provider_profiles: profiles)
             )

    reply =
      Enum.find(result.messages, &(&1["tool_call_id"] == "list"))["content"] |> JSON.decode!()

    assert Enum.map(reply["models"], & &1["model"]) == ["model-a", "model-b"]
    assert reply["backends"] == ["a-unavailable", "worker", "z-unavailable"]

    assert reply["errors"] == [
             %{"backend" => "a-unavailable", "error" => "model discovery failed"},
             %{"backend" => "z-unavailable", "error" => "model discovery failed"}
           ]
  end

  test "agents select arbitrary models at spawn time without configured agent definitions" do
    requests =
      Enum.map(["unlisted-new-model", "model-b"], fn model ->
        Map.put(task(model), "model", model)
      end)

    assert %Alto.Runner.Result{status: :ok} =
             result =
             Alto.Contrib.run(
               "delegate",
               options([call("spawn", "spawn_agents", %{"agents" => requests})])
             )

    reply = Enum.find(result.messages, &(&1["role"] == "tool"))["content"] |> JSON.decode!()
    assert Enum.map(reply["results"], & &1["id"]) == ["unlisted-new-model", "model-b"]
    assert_receive {:selected_model, "unlisted-new-model"}
    assert_receive {:selected_model, "model-b"}
  end

  test "a failed child keeps successful siblings in the provider reply" do
    for {reason, expected} <- [
          {{:http_error, 402, %{"message" => "payment required"}},
           %{
             "$tuple" => ["http_error", 402, %{"message" => "payment required"}]
           }},
          {:unavailable, "unavailable"},
          {"provider offline", "provider offline"}
        ] do
      requests = [task("successful"), task("failed") |> Map.put("model", "model-b")]
      calls = [call("spawn", "spawn_agents", %{"agents" => requests})]

      assert %Alto.Runner.Result{status: :ok} =
               result =
               Alto.Contrib.run(
                 "delegate",
                 options(calls,
                   provider_profiles: [
                     %Alto.Contrib.ProviderProfile{
                       id: "worker",
                       provider:
                         {Child, owner: self(), fail_model: "model-b", fail_reason: reason}
                     }
                   ]
                 )
               )

      reply = Enum.find(result.messages, &(&1["tool_call_id"] == "spawn"))["content"]
      assert %{"results" => [successful, failed]} = JSON.decode!(reply)
      assert %{"id" => "successful", "status" => "ok", "output" => "child done"} = successful
      assert is_binary(successful["run_id"])
      assert successful["usage"]["total_tokens"] == 6
      assert %{"id" => "failed", "status" => "error", "reason" => ^expected} = failed
      refute Map.has_key?(JSON.decode!(reply), "encoding_error")
    end
  end

  test "delegation schemas advertise the effective child limit" do
    for max_children <- [1, 4, 12] do
      calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]

      loop =
        Alto.default_loop(
          subagents: Alto.Subagents.bounded(max_depth: 1, max_children: max_children)
        )

      assert %Alto.Runner.Result{status: :ok} =
               _ = Alto.Contrib.run("delegate", options(calls, loop: loop))

      assert_receive {:request, request}
      assert_receive {:request, _}

      for name <- ["spawn_agents", "start_agents"] do
        schema = Enum.find(request.tools, &(&1["function"]["name"] == name))
        assert schema["function"]["parameters"][:properties][:agents][:maxItems] == max_children
      end
    end
  end

  test "five children run when the configured limit is five" do
    requests = Enum.map(1..5, &task("child-#{&1}"))
    calls = [call("spawn", "spawn_agents", %{"agents" => requests})]
    loop = Alto.default_loop(subagents: Alto.Subagents.bounded(max_depth: 1, max_children: 5))

    assert %Alto.Runner.Result{status: :ok} =
             result = Alto.Contrib.run("delegate", options(calls, loop: loop))

    reply = Enum.find(result.messages, &(&1["tool_call_id"] == "spawn"))["content"]
    assert %{"results" => results} = JSON.decode!(reply)
    assert Enum.map(results, & &1["id"]) == Enum.map(requests, & &1["id"])
    assert Enum.all?(results, &(&1["status"] == "ok"))
    assert result.usage.total_tokens == 30
    for _ <- 1..5, do: assert_receive({:child, _})
  end

  test "five children are rejected before dispatch when the configured limit is four" do
    requests = Enum.map(1..5, &task("child-#{&1}"))
    calls = [call("spawn", "spawn_agents", %{"agents" => requests})]
    loop = Alto.default_loop(subagents: Alto.Subagents.bounded(max_depth: 1, max_children: 4))

    assert %Alto.Runner.Result{status: :ok} =
             result = Alto.Contrib.run("delegate", options(calls, loop: loop))

    assert Enum.any?(
             result.events,
             &(&1.type == :tool_failed and &1.data.error == :max_children_exceeded)
           )

    refute_receive {:child, _}
  end

  test "no-argument tools use the current provider when profiles are omitted" do
    request = task("child", "current_provider") |> Map.put("model", "child-model")
    calls = [call("spawn", "spawn_agents", %{"agents" => [request]})]

    opts =
      options(calls,
        provider_profiles: nil,
        provider: {CurrentProvider, owner: self(), calls: calls, model: "parent-model"}
      )

    assert %Alto.Runner.Result{status: :ok} = result = Alto.Contrib.run("delegate", opts)
    assert result.output == "done"
    assert_receive {:selected_model, "child-model"}
  end

  test "a selected provider resolves credentials from the host store without exposing them" do
    path =
      Path.join(
        System.tmp_dir!(),
        "alto-model-credentials-#{System.unique_integer([:positive])}/credentials.json"
      )

    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)

    assert {:ok, _} =
             Alto.Contrib.ProviderStore.save(
               %{
                 id: "worker",
                 label: "Worker",
                 base_url: "https://provider.test/v1",
                 api_key: "test-private-key"
               },
               [],
               credentials_path: path
             )

    calls = [
      call("list", "list_agent_models", %{}),
      call("spawn", "spawn_agents", %{"agents" => [task()]})
    ]

    assert %Alto.Runner.Result{status: :ok} =
             result = Alto.Contrib.run("delegate", options(calls, credentials_path: path))

    assert_receive {:credential, "test-private-key"}
    refute inspect(result.messages) =~ "test-private-key"
  end

  test "oversized discovery and child results never report a successful tool result" do
    profiles = [
      %Alto.Contrib.ProviderProfile{
        id: "worker",
        provider: {Child, owner: self(), answer: String.duplicate("x", 1_000)},
        models: [%{id: "model-a", name: String.duplicate("x", 1_000)}]
      }
    ]

    for {name, arguments} <- [
          {"list_agent_models", %{}},
          {"spawn_agents", %{"agents" => [task()]}}
        ] do
      assert %Alto.Runner.Result{status: :ok} =
               result =
               Alto.Contrib.run(
                 "delegate",
                 options([call(name, name, arguments)],
                   provider_profiles: profiles,
                   max_tool_result_bytes: 256
                 )
               )

      assert result.verdict == :unknown
      assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.name == name))
      refute Enum.any?(result.events, &(&1.type == :tool_completed and &1.data.name == name))
    end
  end

  test "multiple delegation calls and duplicate call IDs each settle once" do
    calls = Enum.map(1..2, &call("same", "spawn_agents", %{"agents" => [task("child-#{&1}")]}))

    assert %Alto.Runner.Result{status: :ok} =
             result = Alto.Contrib.run("delegate", options(calls))

    assert Enum.count(result.messages, &(&1["role"] == "tool")) == 2
    assert result.usage.total_tokens == 12
  end

  test "unknown agents, extra keys, duplicate IDs and depth violations never dispatch" do
    cases = [
      {%{"agents" => [task("c", "missing")]}, []},
      {%{"agents" => [Map.put(task(), "provider", "evil")]}, []},
      {%{"agents" => [task(), task()]}, []},
      {%{"agents" => [task()]}, [loop: Alto.default_loop()]}
    ]

    for {arguments, overrides} <- cases do
      assert %Alto.Runner.Result{status: :ok} =
               result =
               Alto.Contrib.run(
                 "delegate",
                 options([call("spawn", "spawn_agents", arguments)], overrides)
               )

      assert Enum.any?(result.events, &(&1.type == :tool_failed))
      refute_receive {:child, _}
    end
  end

  test "hidden delegation and denied approval cannot start a child" do
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]

    for overrides <- [[model_tools: [:list_agent_models]], [approval: {:deny, :policy_denied}]] do
      assert %Alto.Runner.Result{status: :ok} =
               result = Alto.Contrib.run("delegate", options(calls, overrides))

      assert Enum.any?(result.events, &(&1.type == :tool_failed))
      refute_receive {:child, _}
    end
  end

  test "model restrictions apply to discovery and dispatch" do
    restricted = Alto.Contrib.Tools.agents(models: %{"worker" => ["model-b"]})

    calls = [
      call("list", "list_agent_models", %{}),
      call("spawn", "spawn_agents", %{"agents" => [task()]})
    ]

    assert %Alto.Runner.Result{status: :ok} =
             result = Alto.Contrib.run("delegate", options(calls, tools: restricted))

    reply =
      Enum.find(result.messages, &(&1["tool_call_id"] == "list"))["content"] |> JSON.decode!()

    assert [%{"model" => "model-b"}] = reply["models"]
    assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.name == "spawn_agents"))
    refute_receive {:child, _}
    allowed = Map.put(task(), "model", "model-b")

    assert %Alto.Runner.Result{status: :ok} =
             _ =
             Alto.Contrib.run(
               "delegate",
               options([call("spawn", "spawn_agents", %{"agents" => [allowed]})],
                 tools: restricted
               )
             )

    assert_receive {:selected_model, "model-b"}
  end

  test "a backend omitted from an explicit model restriction is unavailable" do
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]

    assert %Alto.Runner.Result{status: :ok} =
             result =
             Alto.Contrib.run(
               "delegate",
               options(calls, tools: Alto.Contrib.Tools.agents(models: %{}))
             )

    assert Enum.any?(result.events, &(&1.type == :tool_failed))
    refute_receive {:child, _}
  end

  test "discovery supports filtering and pagination" do
    calls = [
      call("list", "list_agent_models", %{
        "backend" => "worker",
        "query" => "model-",
        "offset" => 1,
        "limit" => 1
      })
    ]

    assert %Alto.Runner.Result{status: :ok} =
             result = Alto.Contrib.run("discover", options(calls))

    reply = Enum.find(result.messages, &(&1["role"] == "tool"))["content"] |> JSON.decode!()
    assert [%{"model" => "model-b"}] = reply["models"]
    assert reply["next_offset"] == nil
  end

  test "a child still consumes the shared model-request budget" do
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]

    assert %Alto.Runner.Result{status: :error, reason: _} =
             result = Alto.Contrib.run("delegate", options(calls, max_model_requests: 1))

    refute_receive {:child, _}
    assert Enum.any?(result.messages, &(&1["role"] == "tool"))
  end

  test "cancelling the parent stops delegated workers" do
    profiles = [%Alto.Contrib.ProviderProfile{id: "worker", provider: {Block, owner: self()}}]
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]

    assert {:ok, handle} =
             Alto.Contrib.start("delegate", options(calls, provider_profiles: profiles))

    assert_receive {:blocking, worker}, 2_000
    monitor = Process.monitor(worker)
    assert :ok = Alto.cancel(handle)
    assert %Alto.Runner.Result{status: :cancelled, reason: _} = _ = Alto.await(handle, 2_000)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
  end

  test "approval checkpoint restores the delegation dispatch and tool correlation" do
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]
    opts = options(calls, approval: :suspend, checkpoint_version: "delegation-1")

    assert %Alto.Runner.Result{status: :suspended, reason: :approval_suspended} =
             suspended = Alto.Contrib.run("delegate", opts)

    refute_receive {:child, _}
    packet = suspended.checkpoint |> JSON.encode!() |> JSON.decode!()

    assert %Alto.Runner.Result{status: :ok} =
             result =
             Alto.Contrib.run("delegate", Keyword.put(opts, :checkpoint, {packet, :approve}))

    assert result.output == "done"
    assert_receive {:child, _}
    assert Enum.count(result.messages, &(&1["role"] == "tool")) == 1
  end
end
