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

      {:ok,
       %{
         message: opts[:answer] || "child done",
         tool_calls: [],
         usage: %{input_tokens: 4, output_tokens: 2}
       }}
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

  defmodule Suspend do
    @behaviour Alto.Approval
    def decide(_, _, _), do: :suspend
  end

  defp call(id, name, arguments),
    do: %{id: id, name: name, arguments_json: JSON.encode!(arguments)}

  defp task(id \\ "child", agent \\ "worker"),
    do: %{"id" => id, "backend" => agent, "model" => "model-a", "task" => "Investigate this"}

  defp options(calls, overrides \\ []) do
    Keyword.merge(
      [
        provider: {Provider, owner: self(), calls: calls},
        tools: Alto.Tools.agents(),
        provider_profiles: [%{id: "worker", provider: {Child, owner: self()}}],
        approval: Alto.Approvals.AllowAll,
        loop:
          Alto.default_loop(
            tool_execution: {:parallel, 4},
            subagents: Alto.Subagents.bounded(max_depth: 1, max_children: 4, max_concurrency: 2)
          )
      ],
      overrides
    )
  end

  test "mixed discovery and delegation settle correlated tool calls and merge child usage" do
    calls = [
      call("list", "list_agent_models", %{}),
      call("spawn", "spawn_agents", %{"agents" => [task()]})
    ]

    assert {:ok, result} = Alto.run("delegate", options(calls))
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

  test "agents select arbitrary models at spawn time without configured agent definitions" do
    requests =
      Enum.map(["unlisted-new-model", "model-b"], fn model ->
        Map.put(task(model), "model", model)
      end)

    assert {:ok, result} =
             Alto.run(
               "delegate",
               options([call("spawn", "spawn_agents", %{"agents" => requests})])
             )

    reply = Enum.find(result.messages, &(&1["role"] == "tool"))["content"] |> JSON.decode!()
    assert Enum.map(reply["results"], & &1["id"]) == ["unlisted-new-model", "model-b"]
    assert_receive {:selected_model, "unlisted-new-model"}
    assert_receive {:selected_model, "model-b"}
  end

  test "no-argument tools use the current provider when profiles are omitted" do
    request = task("child", "current_provider") |> Map.put("model", "child-model")
    calls = [call("spawn", "spawn_agents", %{"agents" => [request]})]

    opts =
      options(calls,
        provider_profiles: nil,
        provider: {CurrentProvider, owner: self(), calls: calls, model: "parent-model"}
      )

    assert {:ok, result} = Alto.run("delegate", opts)
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
             Alto.Harness.ProviderStore.save(
               %{
                 id: "worker",
                 label: "Worker",
                 base_url: "https://provider.test/v1",
                 api_key: "test-private-key"
               },
               credentials_path: path
             )

    calls = [
      call("list", "list_agent_models", %{}),
      call("spawn", "spawn_agents", %{"agents" => [task()]})
    ]

    assert {:ok, result} = Alto.run("delegate", options(calls, credentials_path: path))
    assert_receive {:credential, "test-private-key"}
    refute inspect(result.messages) =~ "test-private-key"
  end

  test "explicit tool selection exposes spawning without discovery" do
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]

    assert {:ok, _} =
             Alto.run("delegate", options(calls, tools: Alto.Tools.agents(only: [:spawn_agents])))

    assert_receive {:request, request}
    assert Enum.map(request.tools, & &1["function"]["name"]) == ["spawn_agents"]
    assert_receive {:selected_model, "model-a"}
  end

  test "oversized combined child results fail without reporting a successful tool result" do
    profiles = [
      %{id: "worker", provider: {Child, owner: self(), answer: String.duplicate("x", 1_000)}}
    ]

    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]

    assert {:ok, result} =
             Alto.run(
               "delegate",
               options(calls, provider_profiles: profiles, max_tool_result_bytes: 256)
             )

    assert result.verdict == :unknown
    assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.name == "spawn_agents"))
  end

  test "multiple delegation calls and duplicate call IDs each settle once" do
    calls = Enum.map(1..2, &call("same", "spawn_agents", %{"agents" => [task("child-#{&1}")]}))
    assert {:ok, result} = Alto.run("delegate", options(calls))
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
      assert {:ok, result} =
               Alto.run(
                 "delegate",
                 options([call("spawn", "spawn_agents", arguments)], overrides)
               )

      assert Enum.any?(result.events, &(&1.type == :tool_failed))
      refute_receive {:child, _}
    end
  end

  test "hidden delegation and denied approval cannot start a child" do
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]

    for overrides <- [[model_tools: [:list_agent_models]], [approval: Alto.Approvals.DenyAll]] do
      assert {:ok, result} = Alto.run("delegate", options(calls, overrides))
      assert Enum.any?(result.events, &(&1.type == :tool_failed))
      refute_receive {:child, _}
    end
  end

  test "model restrictions apply to discovery and dispatch" do
    restricted = Alto.Tools.agents(models: %{"worker" => ["model-b"]})

    calls = [
      call("list", "list_agent_models", %{}),
      call("spawn", "spawn_agents", %{"agents" => [task()]})
    ]

    assert {:ok, result} = Alto.run("delegate", options(calls, tools: restricted))

    reply =
      Enum.find(result.messages, &(&1["tool_call_id"] == "list"))["content"] |> JSON.decode!()

    assert [%{"model" => "model-b"}] = reply["models"]
    assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.name == "spawn_agents"))
    refute_receive {:child, _}
    allowed = Map.put(task(), "model", "model-b")

    assert {:ok, _} =
             Alto.run(
               "delegate",
               options([call("spawn", "spawn_agents", %{"agents" => [allowed]})],
                 tools: restricted
               )
             )

    assert_receive {:selected_model, "model-b"}
  end

  test "a backend omitted from an explicit model restriction is unavailable" do
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]

    assert {:ok, result} =
             Alto.run("delegate", options(calls, tools: Alto.Tools.agents(models: %{})))

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

    assert {:ok, result} = Alto.run("discover", options(calls))
    reply = Enum.find(result.messages, &(&1["role"] == "tool"))["content"] |> JSON.decode!()
    assert [%{"model" => "model-b"}] = reply["models"]
    assert reply["next_offset"] == nil
  end

  test "a child still consumes the shared model-request budget" do
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]
    assert {:error, _, result} = Alto.run("delegate", options(calls, max_model_requests: 1))
    refute_receive {:child, _}
    assert Enum.any?(result.messages, &(&1["role"] == "tool"))
  end

  test "cancelling the parent stops delegated workers" do
    profiles = [%{id: "worker", provider: {Block, owner: self()}}]
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]
    assert {:ok, handle} = Alto.start("delegate", options(calls, provider_profiles: profiles))
    assert_receive {:blocking, worker}, 2_000
    monitor = Process.monitor(worker)
    assert :ok = Alto.cancel(handle)
    assert {:error, {:cancelled, _}, _} = Alto.await(handle, 2_000)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
  end

  test "approval checkpoint restores the delegation dispatch and tool correlation" do
    calls = [call("spawn", "spawn_agents", %{"agents" => [task()]})]
    opts = options(calls, approval: Suspend, checkpoint_version: "delegation-1")
    assert {:error, :approval_suspended, suspended} = Alto.run("delegate", opts)
    refute_receive {:child, _}
    packet = suspended.checkpoint |> JSON.encode!() |> JSON.decode!()

    assert {:ok, result} =
             Alto.run("delegate", Keyword.put(opts, :checkpoint, {packet, :approve}))

    assert result.output == "done"
    assert_receive {:child, _}
    assert Enum.count(result.messages, &(&1["role"] == "tool")) == 1
  end
end
