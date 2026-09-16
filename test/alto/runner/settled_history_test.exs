defmodule Alto.Runner.SettledHistoryTest do
  use ExUnit.Case, async: true

  defmodule Change do
    @behaviour Alto.Tool
    def name, do: :change
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :exclusive
    def approval, do: :required

    def run(_, context, opts) do
      File.write!(Path.join(context.cwd, "changed"), "yes")
      send(opts[:owner], {:changed, self()})

      if opts[:block],
        do:
          (receive do
             :release -> :ok
           end)

      {:ok, "changed"}
    end
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _, opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        send(opts[:owner], {:after_tool, request.messages, self()})

        if opts[:instant] do
          {:ok, %{message: "done", tool_calls: []}}
        else
          receive do
            :release -> {:ok, %{message: "done", tool_calls: []}}
          end
        end
      else
        {:ok,
         %{message: nil, tool_calls: [%{id: "change-call", name: "change", arguments_json: "{}"}]}}
      end
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-settled-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    id = Alto.Session.generate_id()

    opts = [
      session: id,
      session_dir: dir,
      cwd: dir,
      session_history: :settled,
      provider: {Provider, owner: self()},
      tools: [{Change, owner: self()}],
      approval: Alto.Approvals.AllowAll
    ]

    %{dir: dir, id: id, opts: opts}
  end

  test "a crash during the next model retains the completed tool turn", %{
    id: id,
    opts: opts,
    dir: dir
  } do
    {:ok, handle} = Alto.start("change", opts)
    assert_receive {:after_tool, history, _}, 1000
    assert {:error, _, _} = Alto.Runner.terminate(handle)
    assert {:ok, snapshot} = Alto.Session.transcript(id, session_dir: dir)
    assert snapshot.messages == history
    assert Enum.any?(snapshot.messages, &(&1["role"] == "tool" and &1["content"] == "changed"))
    assert File.read!(Path.join(dir, "changed")) == "yes"

    resume_opts =
      Keyword.put(opts, :provider, {Provider, owner: self(), instant: true})

    assert {:ok, resumed} = Alto.resume(id, "continue", resume_opts)
    assert resumed.transcript_persisted
    assert {:ok, resumed_snapshot} = Alto.Session.transcript(id, session_dir: dir)
    assert resumed.transcript_revision == resumed_snapshot.revision
    assert Enum.any?(resumed.messages, &(&1["role"] == "tool" and &1["content"] == "changed"))
    assert Enum.any?(resumed.messages, &(&1 == %{"role" => "user", "content" => "continue"}))
  end

  test "hard death after native dispatch leaves a fence that prevents ordinary resume", %{
    id: id,
    opts: opts,
    dir: dir
  } do
    opts =
      opts
      |> Keyword.put(:provider, nil)
      |> Keyword.put(:loop, Alto.rule_loop(steps: ["change"]))
      |> Keyword.put(:tools, [{Change, owner: self(), block: true}])

    {:ok, handle} = Alto.start(%{}, opts)
    assert_receive {:changed, _}, 1000
    assert {:error, _, _} = Alto.Runner.terminate(handle)

    assert {:error, {:session_unsettled_tool_dispatch, fence}} =
             Alto.Session.transcript(id, session_dir: dir)

    assert length(fence.tool_call_ids) == 1
    assert File.read!(Path.join(dir, "changed")) == "yes"
  end

  test "cooperative cancellation retains an explicit unknown native outcome", %{
    id: id,
    opts: opts,
    dir: dir
  } do
    opts =
      opts
      |> Keyword.put(:provider, nil)
      |> Keyword.put(:loop, Alto.rule_loop(steps: ["change"]))
      |> Keyword.put(:tools, [{Change, owner: self(), block: true}])

    {:ok, handle} = Alto.start(%{}, opts)
    assert_receive {:changed, _}, 1000
    assert :ok = Alto.cancel(handle)
    assert {:error, {:cancelled, :user}, result} = Alto.await(handle)
    assert result.verdict == :unknown
    assert result.persistence == :ok
    assert result.transcript_persisted
    assert result.resolved_operations == []
    assert {:ok, snapshot} = Alto.Session.transcript(id, session_dir: dir)
    assert result.transcript_revision == snapshot.revision
    assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.outcome == :unknown))
  end

  test "cooperative cancellation closes a provider tool call with an unknown reply", %{
    id: id,
    opts: opts,
    dir: dir
  } do
    opts = Keyword.put(opts, :tools, [{Change, owner: self(), block: true}])

    {:ok, handle} = Alto.start("change", opts)
    assert_receive {:changed, _}, 1000
    assert :ok = Alto.cancel(handle)
    assert {:error, {:cancelled, :user}, result} = Alto.await(handle)

    assert result.verdict == :unknown
    assert result.transcript_persisted
    assert result.resolved_operations == []
    assert :ok = Alto.Context.Transcript.validate(result.messages)

    assert Enum.any?(result.messages, fn
             %{"role" => "tool", "tool_call_id" => "change-call"} -> true
             _ -> false
           end)

    assert Enum.any?(result.events, &(&1.type == :tool_failed and &1.data.outcome == :unknown))

    assert {:ok, snapshot} = Alto.Session.transcript(id, session_dir: dir)
    assert snapshot.messages == result.messages
    assert snapshot.revision == result.transcript_revision
  end

  test "settled history composes with suspended prepared approval", %{
    id: id,
    opts: opts,
    dir: dir
  } do
    opts =
      Keyword.merge(opts, approval: Alto.Approvals.Checkpoint, checkpoint_version: "history-v1")

    assert {:error, :approval_suspended, paused} = Alto.run("change", opts)

    {:ok, handle} =
      Alto.start("change", Keyword.put(opts, :checkpoint, {paused.checkpoint, :approve}))

    assert_receive {:after_tool, _, worker}, 1000
    send(worker, :release)
    assert {:ok, result} = Alto.await(handle)
    assert result.persistence == :ok
    assert {:ok, _} = Alto.Session.transcript(id, session_dir: dir)
  end
end
