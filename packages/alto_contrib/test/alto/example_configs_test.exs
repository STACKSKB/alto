defmodule Alto.Contrib.ExampleConfigsTest do
  use ExUnit.Case, async: false
  alias Alto.Contrib.{Config, ProviderProfile}
  alias Alto.Contrib.Providers.OpenAICompatible

  @repository Path.expand("../../../..", __DIR__)
  @profiles ~w(minimal review workspace team assistant)

  defmodule Adapter do
    def run(request) do
      script = Req.Request.get_private(request, :example_script)
      owner = Req.Request.get_private(request, :example_owner)
      send(owner, {:example_wire, script, request.method, JSON.decode!(request.body)})
      response = Agent.get_and_update(script, fn [next | rest] -> {next, rest} end)

      response =
        Req.Response.new(
          status: 200,
          headers: [{"content-type", "application/json"}],
          body: response
        )

      {:cont, result} = request.into.({:data, JSON.encode!(response.body)}, {request, response})
      result
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "alto-example-configs-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "AGENTS.md"), "Fixture workspace guidance: cite evidence.\n")
    File.write!(Path.join(cwd, "notes.txt"), "original evidence\n")

    env = %{
      "ALTO_MODEL" => "fixture-model",
      "ALTO_BASE_URL" => "http://example.invalid/v1",
      "ALTO_API_KEY" => "fixture-key"
    }

    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(env)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root, cwd: cwd, session_dir: Path.join(root, "sessions")}
  end

  test "each independently loaded example needs a model and completes a native HTTP tool round trip",
       ctx do
    System.delete_env("ALTO_MODEL")

    for name <- @profiles do
      assert {:error, {:config_load_failed, _, message}} = Config.load(path(name))
      assert message =~ "ALTO_MODEL"
    end

    System.put_env("ALTO_MODEL", "fixture-model")

    for name <- @profiles do
      {options, script} =
        configured(name, ctx, [
          calls([call("read", "read_file", %{path: "notes.txt"})]),
          answer(name)
        ])

      result = Alto.Contrib.run("Read the evidence", options)
      assert result.status == :ok, inspect(result.reason)
      assert result.output == name
      assert tool_reply(result, "read")["content"] == "original evidence\n"
      assert result.persistence == :ok
      assert_receive {:example_wire, ^script, :post, request}
      assert request["model"] == "fixture-model"

      assert Enum.any?(
               request["messages"],
               &String.contains?(&1["content"] || "", "Fixture workspace guidance")
             )

      assert Agent.get(script, & &1) == []
    end
  end

  test "minimal executes approved writes, exact edits and host commands, then resumes its saved session",
       ctx do
    responses = [
      calls([call("write", "write_file", %{path: "draft.txt", content: "before\n"})]),
      calls([
        call("edit", "edit_file", %{
          path: "draft.txt",
          edits: [%{old_text: "before", new_text: "after"}]
        })
      ]),
      calls([call("command", "run_command", %{program: "printf", args: ["%s", "checked"]})]),
      answer("completed"),
      answer("resumed")
    ]

    {options, script} = configured("minimal", ctx, responses)
    owner = self()

    options =
      Keyword.put(options, :approval, fn request, _ ->
        send(owner, {:approved, request.tool})
        :approve
      end)

    result = Alto.Contrib.run("Create and check a draft", options)
    assert result.status == :ok, inspect(result.reason)
    assert File.read!(Path.join(ctx.cwd, "draft.txt")) == "after\n"
    assert tool_reply(result, "command")["output"] == "checked"
    for name <- ~w(write_file edit_file run_command), do: assert_receive({:approved, ^name})

    assert %{status: :ok, output: "resumed", session_id: session_id} =
             Alto.Contrib.resume(result.session_id, "Continue", options)

    assert session_id == result.session_id
    requests = wire_requests(script)
    assert length(requests) == 5

    assert Enum.any?(
             List.last(requests)["messages"],
             &(&1["role"] == "assistant" and &1["content"] == "completed")
           )

    assert {:ok, transcript} = Alto.Session.transcript(session_id, session_dir: ctx.session_dir)
    assert List.last(transcript["messages"])["content"] == "resumed"
  end

  test "review denial policy still rejects writes when a host composes in a mutation tool", ctx do
    {options, _} =
      configured("review", ctx, [
        calls([call("write", "write_file", %{path: "denied.txt", content: "no"})]),
        answer("denied")
      ])

    result =
      Alto.Contrib.run(
        "Write only if approved",
        Keyword.update!(options, :tools, &(&1 ++ [Alto.Contrib.Tools.WriteFile]))
      )

    assert result.status == :ok, inspect(result.reason)
    refute File.exists?(Path.join(ctx.cwd, "denied.txt"))

    assert Enum.any?(
             result.events,
             &(&1.type == :tool_failed and &1.data.error == {:approval_denied, :read_only_profile})
           )
  end

  test "review inspects text and Git but cannot dispatch a write tool", ctx do
    git!(ctx.cwd, ["init", "--quiet"])
    git!(ctx.cwd, ["add", "."])
    git!(ctx.cwd, ["commit", "--quiet", "-m", "fixture"])

    {options, _} =
      configured("review", ctx, [
        calls([
          call("search", "search_files", %{query: "evidence"}),
          call("git", "git_inspect", %{action: "log", limit: 1}),
          call("write", "write_file", %{path: "notes.txt", content: "changed"})
        ]),
        answer("reviewed")
      ])

    result = Alto.Contrib.run("Review the evidence", options)
    assert result.status == :ok, inspect(result.reason)
    assert tool_reply(result, "search")["matches"] != []
    assert tool_reply(result, "git")["output"] =~ "fixture"
    assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.name == "write_file"))
    assert File.read!(Path.join(ctx.cwd, "notes.txt")) == "original evidence\n"
    assert git!(ctx.cwd, ["status", "--porcelain"]) == ""
  end

  test "team discovers the static backend, delegates a bounded read and saves a distinct child session",
       ctx do
    {options, script} =
      configured("team", ctx, [
        calls([
          call("models", "list_agent_models", %{}),
          call("spawn", "spawn_agents", %{agents: [agent("worker")]})
        ]),
        calls([
          call("read", "read_file", %{path: "notes.txt"}),
          call("nested", "spawn_agents", %{agents: [agent("grandchild")]})
        ]),
        answer("child evidence"),
        answer("combined evidence")
      ])

    result =
      Alto.Contrib.run("Delegate one investigation", Keyword.put(options, :approval, :approve))

    assert result.status == :ok, inspect(result.reason)

    assert tool_reply(result, "models")["models"] == [
             %{"backend" => "configured", "model" => "fixture-model", "name" => "fixture-model"}
           ]

    assert [%{"status" => "ok", "output" => "child evidence"}] =
             tool_reply(result, "spawn")["results"]

    assert {:ok, sessions} = Alto.Session.list(session_dir: ctx.session_dir)
    assert length(sessions) == 2
    assert length(Enum.uniq_by(sessions, & &1.id)) == 2
    assert result.session_id in Enum.map(sessions, & &1.id)
    assert Agent.get(script, & &1) == []
    assert [_, _, child_reply, _] = wire_requests(script)
    nested = Enum.find(child_reply["messages"], &(&1["tool_call_id"] == "nested"))
    assert nested["content"] =~ "max_depth_exceeded"
  end

  test "team rejects an oversized batch and an unconfigured child model without child requests",
       ctx do
    for agents <- [
          Enum.map(1..4, &agent("worker-#{&1}")),
          [Map.put(agent("worker"), :model, "other-model")]
        ] do
      {options, script} =
        configured("team", ctx, [
          calls([call("spawn", "spawn_agents", %{agents: agents})]),
          answer("rejected")
        ])

      result =
        Alto.Contrib.run("Validate this delegation", Keyword.put(options, :approval, :approve))

      assert result.status == :ok, inspect(result.reason)

      assert Enum.any?(
               result.events,
               &(&1.type == :tool_failed and &1.data.name == "spawn_agents")
             )

      assert length(wire_requests(script)) == 2
    end
  end

  test "assistant publishes a full in-limit file through text-only transport and rejects the next byte",
       ctx do
    bytes = :binary.copy(<<0, 255>>, 128_000)
    File.write!(Path.join(ctx.cwd, "result.bin"), bytes)
    File.write!(Path.join(ctx.cwd, "oversized.bin"), bytes <> <<0>>)

    {options, script} =
      configured("assistant", ctx, [
        calls([
          call("publish", "publish_file", %{path: "result.bin"}),
          call("oversized", "publish_file", %{path: "oversized.bin"})
        ]),
        answer("published")
      ])

    result = Alto.Contrib.run("Publish the requested output", options)
    assert result.status == :ok, inspect(result.reason)

    event =
      Enum.find(result.events, &(&1.type == :tool_completed and &1.data.name == "publish_file"))

    assert %Alto.Content{blocks: blocks} = event.data.value
    artifact = Enum.find(blocks, &(&1["type"] == "artifact"))
    assert Base.decode64!(artifact["data"]) == bytes
    assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.name == "publish_file"))
    assert [_, request] = wire_requests(script)

    assert Enum.any?(
             request["messages"],
             &String.contains?(&1["content"] || "", "Generated file: result.bin")
           )

    refute JSON.encode!(request) =~ Base.encode64(bytes)
  end

  defp path(name), do: Path.join(@repository, "alto.example.#{name}.exs")

  defp agent(id),
    do: %{
      id: id,
      backend: "configured",
      model: "fixture-model",
      task: "Read notes.txt and report evidence"
    }

  defp configured(name, ctx, responses) do
    {:ok, options} = Config.load(path(name))

    script =
      start_supervised!(Supervisor.child_spec({Agent, fn -> responses end}, id: make_ref()))

    owner = self()

    transport = [
      adapter: Adapter,
      plugins: [
        fn request ->
          request
          |> Req.Request.put_private(:example_script, script)
          |> Req.Request.put_private(:example_owner, owner)
        end
      ]
    ]

    {OpenAICompatible, provider_options} = options[:provider]
    provider = {OpenAICompatible, Keyword.put(provider_options, :req_options, transport)}

    profiles =
      Enum.map(options[:provider_profiles], fn %ProviderProfile{} = profile ->
        %{profile | provider: provider}
      end)

    options =
      Keyword.merge(options,
        provider: provider,
        provider_profiles: profiles,
        cwd: ctx.cwd,
        session_dir: ctx.session_dir,
        credentials_path: Path.join(ctx.root, "credentials.json")
      )

    {options, script}
  end

  defp call(id, name, arguments),
    do: %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => JSON.encode!(arguments)}
    }

  defp calls(calls), do: response(%{"content" => nil, "tool_calls" => calls}, "tool_calls")
  defp answer(text), do: response(%{"content" => text}, "stop")

  defp response(message, reason),
    do: %{
      "choices" => [%{"message" => message, "finish_reason" => reason}],
      "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 10, "total_tokens" => 110}
    }

  defp tool_reply(result, id),
    do:
      result.messages
      |> Enum.find(&(&1["role"] == "tool" and &1["tool_call_id"] == id))
      |> Map.fetch!("content")
      |> JSON.decode!()

  defp wire_requests(script, acc \\ []) do
    receive do
      {:example_wire, ^script, :post, body} -> wire_requests(script, [body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp git!(cwd, args) do
    {output, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "core.hooksPath=/dev/null",
          "-c",
          "user.name=Fixture",
          "-c",
          "user.email=fixture@example.invalid",
          "-c",
          "commit.gpgsign=false",
          "-C",
          cwd | args
        ],
        stderr_to_stdout: true
      )

    output
  end
end
