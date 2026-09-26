defmodule Alto.Runner.AgentMessagingTest do
  use ExUnit.Case, async: true
  @timeout 5_000

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _, opts) do
      task = Enum.find(request.messages, &(&1["role"] == "user"))["content"]
      send(opts[:owner], {:request, task, request, self()})

      receive do
        {:answer, answer} -> {:ok, Map.put(answer, :usage, %{input_tokens: 1, output_tokens: 1})}
        {:fail, reason} -> {:error, reason}
      end
    end
  end

  defmodule BlockingTool do
    use Alto.Tool, name: :block, execution_mode: :exclusive, approval: :never
    def schema(_), do: Alto.Tool.object_schema("block", %{}, [])

    def run(_, _, opts) do
      send(opts[:owner], {:tool, self()})
      receive do: (:finish -> {:ok, "finished"})
    end
  end

  defmodule SlowStart do
    @behaviour Alto.Runner
    def run(task, opts), do: Alto.Runner.Serial.run(task, opts)

    def start(task, opts) do
      result = Alto.Runner.Serial.start(task, opts)

      if Keyword.get(opts, :agent_depth, 0) > 0 do
        receive do: (:release_start -> result)
      else
        result
      end
    end

    defdelegate await(handle, timeout), to: Alto.Runner.Serial
    defdelegate cancel(handle, reason), to: Alto.Runner.Serial
    defdelegate terminate(handle, reason), to: Alto.Runner.Serial
    defdelegate subscribe(handle, pid), to: Alto.Runner.Serial
  end

  defp options(extra \\ []) do
    Keyword.merge(
      [
        provider: {Provider, owner: self()},
        tools: Alto.Tools.agents(),
        approval: Alto.Approvals.AllowAll,
        loop:
          Alto.default_loop(
            subagents:
              Alto.Subagents.bounded(
                max_depth: 1,
                max_children: 4,
                max_concurrency: 1
              )
          ),
        run_timeout: 15_000
      ],
      extra
    )
  end

  defp answer(pid, text), do: send(pid, {:answer, %{message: text, tool_calls: []}})

  defp tool(pid, name, args) do
    id = "call-#{System.unique_integer([:positive])}"

    send(
      pid,
      {:answer,
       %{
         message: nil,
         tool_calls: [
           %{id: id, name: name, arguments_json: JSON.encode!(args)}
         ]
       }}
    )
  end

  defp agent(task),
    do: %{"id" => task, "task" => task, "backend" => "provider", "model" => "test"}

  defp reply(request) do
    request.messages
    |> Enum.filter(&(&1["role"] == "tool"))
    |> List.last()
    |> Map.fetch!("content")
    |> JSON.decode!()
  end

  test "parent and child exchange attributed steering while joined, without replacing the task" do
    {:ok, router} = Alto.Messaging.start_link()
    {:ok, handle} = Alto.start("root", options(messaging: router))
    assert_receive {:request, "root", _, root}, @timeout
    tool(root, "start_agents", %{"agents" => [agent("child")]})
    assert_receive {:request, "root", started, root}, @timeout
    [%{"agent_id" => child_id}] = reply(started)["agents"]
    assert_receive {:request, "child", _, child}, @timeout
    {:ok, agents} = Alto.Messaging.list(router)
    root_id = Enum.find(agents, &is_nil(&1.parent)).agent_id
    tool(root, "wait_agents", %{"agents" => [child_id]})
    tool(child, "send_message", %{"to" => root_id, "text" => "Which parser?"})
    assert_receive {:request, "child", sent, child}, @timeout
    assert reply(sent)["status"] == "queued"
    tool(child, "wait_agents", %{"agents" => []})
    assert_receive {:request, "root", question, root}, @timeout
    assert :ok = Alto.Context.Transcript.validate(question.messages)
    assert List.last(question.messages)["content"] =~ "Which parser?"
    assert List.last(question.messages)["content"] =~ child_id
    tool(root, "send_message", %{"to" => child_id, "text" => "The JSON parser."})
    assert_receive {:request, "root", _, root}, @timeout
    tool(root, "wait_agents", %{"agents" => [child_id]})
    assert_receive {:request, "child", response, child}, @timeout
    assert List.last(response.messages)["content"] =~ "The JSON parser."
    assert :ok = Alto.Context.Transcript.validate(response.messages)
    answer(child, "child done")
    assert_receive {:request, "root", joined, root}, @timeout
    assert [%{"result" => %{"output" => "child done"}}] = reply(joined)["agents"]
    # Repeated observation must not charge usage twice.
    tool(root, "wait_agents", %{"agents" => [child_id], "timeout_ms" => 0})
    assert_receive {:request, "root", _, root}, @timeout
    answer(root, "root done")
    assert {:ok, result} = Alto.await(handle)
    assert result.loop_state.task == "root"
    assert result.output == "root done"
    assert result.usage.total_tokens == 18
    assert :ok = Alto.Context.Transcript.validate(result.messages)
    assert {:error, :recipient_closed} = Alto.Messaging.send(router, child_id, text: "late")
  end

  test "a waiting child releases the only slot so a queued sibling can answer" do
    {:ok, handle} = Alto.start("root", options())
    assert_receive {:request, "root", _, root}, @timeout
    tool(root, "start_agents", %{"agents" => [agent("a"), agent("b")]})
    assert_receive {:request, "root", started, root}, @timeout
    [%{"agent_id" => a}, %{"agent_id" => b}] = reply(started)["agents"]
    assert_receive {:request, "a", _, first}, @timeout
    refute_receive {:request, "b", _, _}, 30
    tool(root, "wait_agents", %{"agents" => [a]})
    tool(first, "wait_agents", %{"agents" => []})
    assert_receive {:request, "b", _, second}, @timeout
    tool(second, "send_message", %{"to" => a, "text" => "You can proceed."})
    assert_receive {:request, "b", _, second}, @timeout
    # The waiting child does not resume model execution before a slot is free.
    refute_receive {:request, "a", _, _}, 30
    answer(second, "b done")
    assert_receive {:request, "a", resumed, first}, @timeout
    assert List.last(resumed.messages)["content"] =~ "You can proceed."
    answer(first, "a done")
    assert_receive {:request, "root", _, root}, @timeout
    tool(root, "wait_agents", %{"agents" => [b, a], "timeout_ms" => 0})
    assert_receive {:request, "root", joined, root}, @timeout
    assert Enum.map(reply(joined)["agents"], & &1["id"]) == ["b", "a"]
    answer(root, "done")
    assert {:ok, _} = Alto.await(handle)
  end

  test "async child errors preserve successful siblings in provider replies" do
    {:ok, handle} = Alto.start("root", options())
    assert_receive {:request, "root", _, root}, @timeout
    tool(root, "start_agents", %{"agents" => [agent("successful"), agent("failed")]})
    assert_receive {:request, "root", started, root}, @timeout
    [%{"agent_id" => successful_id}, %{"agent_id" => failed_id}] = reply(started)["agents"]
    tool(root, "wait_agents", %{"agents" => [failed_id]})
    assert_receive {:request, "successful", _, child}, @timeout
    answer(child, "child done")
    assert_receive {:request, "failed", _, child}, @timeout
    send(child, {:fail, {:http_error, 402, %{"message" => "payment required"}}})
    assert_receive {:request, "root", _, root}, @timeout
    tool(root, "wait_agents", %{"agents" => [successful_id, failed_id], "timeout_ms" => 0})
    assert_receive {:request, "root", joined, root}, @timeout
    [%{"result" => successful}, %{"result" => failed}] = reply(joined)["agents"]
    assert %{"id" => "successful", "status" => "ok", "output" => "child done"} = successful
    assert is_binary(successful["run_id"])
    assert successful["usage"]["total_tokens"] == 2

    assert %{
             "id" => "failed",
             "status" => "error",
             "error" => %{
               "$tuple" => [
                 "model_request_failed",
                 %{"$tuple" => ["http_error", 402, %{"message" => "payment required"}]}
               ]
             }
           } = failed

    answer(root, "done")
    assert {:ok, result} = Alto.await(handle)
    assert :ok = Alto.Context.Transcript.validate(result.messages)
  end

  test "user steering waits for dispatched tools to settle and preserves call correlation" do
    {:ok, input} = Alto.Input.start_link()

    {:ok, handle} =
      Alto.start("root", options(input: input, tools: [{BlockingTool, owner: self()}]))

    assert_receive {:request, "root", _, root}, @timeout
    tool(root, "block", %{})
    assert_receive {:tool, worker}, @timeout
    assert {:ok, receipt} = Alto.Messaging.send(input, text: "new direction")
    refute_receive {:request, _, _, _}, 30
    send(worker, :finish)
    assert_receive {:request, "root", request, root}, @timeout
    assert List.last(request.messages)["content"] == "new direction"
    assert :ok = Alto.Context.Transcript.validate(request.messages)
    assert {:ok, %{status: :consumed}} = Alto.Input.receipt(input, receipt.message_id)
    answer(root, "done")
    assert {:ok, result} = Alto.await(handle)
    assert result.loop_state.task == "new direction"
  end

  test "parent cancellation interrupts waits and terminates running and queued children" do
    {:ok, router} = Alto.Messaging.start_link()
    {:ok, handle} = Alto.start("root", options(messaging: router))
    assert_receive {:request, "root", _, root}, @timeout
    tool(root, "start_agents", %{"agents" => [agent("a"), agent("b")]})
    assert_receive {:request, "root", started, root}, @timeout
    [%{"agent_id" => a}, _] = reply(started)["agents"]
    assert_receive {:request, "a", _, child}, @timeout
    monitor = Process.monitor(child)
    tool(root, "wait_agents", %{"agents" => [a]})
    :ok = Alto.cancel(handle)
    assert {:error, {:cancelled, :user}, _} = Alto.await(handle)
    assert_receive {:DOWN, ^monitor, :process, ^child, _}, @timeout
    refute_receive {:request, "b", _, _}, 30
    {:ok, agents} = Alto.Messaging.list(router)
    assert Enum.all?(agents, &(&1.status == :closed))
  end

  test "invalid waits reacquire their slot before returning a tool error" do
    {:ok, handle} = Alto.start("root", options())
    assert_receive {:request, "root", _, root}, @timeout
    tool(root, "start_agents", %{"agents" => [agent("a"), agent("b")]})
    assert_receive {:request, "root", started, root}, @timeout
    [%{"agent_id" => a}, _] = reply(started)["agents"]
    assert_receive {:request, "a", _, first}, @timeout
    tool(root, "wait_agents", %{"agents" => [a]})
    tool(first, "wait_agents", %{"agents" => ["missing"]})
    assert_receive {:request, "b", _, second}, @timeout
    refute_receive {:request, "a", _, _}, 30
    answer(second, "done")
    assert_receive {:request, "a", request, first}, @timeout
    assert reply(request)["error"] == "unknown_agent"
    answer(first, "done")
    assert_receive {:request, "root", _, root}, @timeout
    answer(root, "done")
    assert {:ok, _} = Alto.await(handle)
  end

  test "async dispatch cannot multiply the root model-request allowance" do
    {:ok, handle} = Alto.start("root", options(max_model_requests: 1))
    assert_receive {:request, "root", _, root}, @timeout
    tool(root, "start_agents", %{"agents" => [agent("a"), agent("b")]})

    assert {:error, {:model_request_failed, {:model_request_limit, 1}}, result} =
             Alto.await(handle)

    assert result.usage.requests == 1
    refute_receive {:request, _, _, _}, 30
  end

  defmodule Guarded do
    use Alto.Tool, name: :guarded, execution_mode: :exclusive, approval: :required
    def schema(_), do: Alto.Tool.object_schema("guarded", %{}, [])
    def run(_, _, _), do: {:ok, "approved"}
  end

  defmodule SelectiveApproval do
    @behaviour Alto.Approval
    def decide(%{tool: "guarded"}, _, _), do: :suspend
    def decide(_, _, _), do: :approve
  end

  defp wait_paused(sender, attempts \\ 200)
  defp wait_paused(_, 0), do: flunk("child was not paused")

  defp wait_paused(sender, attempts) do
    if Alto.Messaging.paused?(sender) != true do
      Process.sleep(10)
      wait_paused(sender, attempts - 1)
    end
  end

  for transport <- [:memory, :file] do
    test "#{transport} checkpoint restores paused children, queued sibling, stable addresses and receipts" do
      directory =
        Path.join(System.tmp_dir!(), "alto-async-mailboxes-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(directory) end)

      transport =
        if unquote(transport) == :file,
          do: {Alto.Messaging.Transport.File, directory: directory},
          else: nil

      {:ok, router} = Alto.Messaging.start_link(transport: transport)

      opts =
        options(
          checkpoint_version: "v1",
          approval: SelectiveApproval,
          tools: Alto.Tools.agents() ++ [Guarded],
          messaging: router
        )

      {:ok, handle} = Alto.start("root", opts)
      assert_receive {:request, "root", _, root}, @timeout
      tool(root, "start_agents", %{"agents" => [agent("a"), agent("b")]})
      assert_receive {:request, "root", started, root}, @timeout
      [%{"agent_id" => a}, %{"agent_id" => b}] = reply(started)["agents"]
      assert_receive {:request, "a", _, child}, @timeout

      {:ok, receipt} =
        Alto.Messaging.send(router, a, text: "queued direction", idempotency_key: "steer-1")

      tool(root, "guarded", %{})
      {:ok, sender} = Alto.Messaging.resolve(router, a)
      wait_paused(sender)
      # The in-flight model request settles once; its answer must not be replayed.
      answer(child, "a finished")
      assert {:error, :approval_suspended, suspended} = Alto.await(handle)
      refute_receive {:request, "b", _, _}, 30
      packet = suspended.checkpoint |> JSON.encode!() |> JSON.decode!()
      {:ok, restored_router} = Alto.Messaging.start_link(transport: transport)

      {:ok, resumed} =
        Alto.start(
          "ignored",
          opts
          |> Keyword.put(:messaging, restored_router)
          |> Keyword.put(:checkpoint, {packet, :approve})
        )

      assert_receive {:request, "root", _, root}, @timeout
      assert_receive {:request, "a", request, child}, @timeout
      assert List.last(request.messages)["content"] == "queued direction"

      assert {:ok, %{message_id: id, status: :consumed}} =
               Alto.Messaging.send(restored_router, a,
                 text: "queued direction",
                 idempotency_key: "steer-1"
               )

      assert id == receipt.message_id
      answer(child, "a resumed")
      assert_receive {:request, "b", _, child}, @timeout
      answer(child, "b done")
      tool(root, "wait_agents", %{"agents" => [a, b]})
      assert_receive {:request, "root", joined, root}, @timeout
      assert Enum.map(reply(joined)["agents"], & &1["agent_id"]) == [a, b]
      answer(root, "done")
      assert {:ok, result} = Alto.await(resumed)
      assert :ok = Alto.Context.Transcript.validate(result.messages)
    end
  end

  test "cancellation during child startup preserves uncertainty and stops an unreturned handle" do
    {:ok, handle} = Alto.start("root", options(runner: SlowStart))
    assert_receive {:request, "root", _, root}, @timeout
    tool(root, "start_agents", %{"agents" => [agent("a")]})
    assert_receive {:request, "root", _, _root}, @timeout
    assert_receive {:request, "a", _, child}, @timeout
    monitor = Process.monitor(child)
    :ok = Alto.cancel(handle)
    assert {:error, {:cancelled, :user}, result} = Alto.await(handle)
    assert result.verdict == :unknown
    assert_receive {:DOWN, ^monitor, :process, ^child, _}, @timeout
  end
end
