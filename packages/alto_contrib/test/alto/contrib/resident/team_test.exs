defmodule Alto.Contrib.Resident.TeamTest do
  use ExUnit.Case, async: true

  defmodule LeadProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:test_pid], {:lead_request, request})

      stages =
        Enum.flat_map(request.messages, fn message ->
          case JSON.decode(message["content"] || "") do
            {:ok, %{"type" => "alto_resident_team_stage", "stage" => stage}} -> [stage]
            _ -> []
          end
        end)

      if List.last(stages) == "integrating" do
        {:ok, %{message: "integrated", tool_calls: []}}
      else
        {:ok,
         %{
           message: ~s({"agents":[{"id":"worker-1","profile":"cheap","task":"inspect"}]}),
           tool_calls: []
         }}
      end
    end
  end

  defmodule CheapProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:test_pid], {:worker_request, request})
      {:ok, %{message: "finding", tool_calls: []}}
    end
  end

  defmodule PlanProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}
    def stream(_request, _sink, opts), do: {:ok, %{message: opts[:plan], tool_calls: []}}
  end

  test "invalid assignments reject the whole plan without dispatching valid siblings", %{dir: dir} do
    child = %{"id" => "valid", "profile" => "cheap", "task" => "inspect"}

    invalid = [
      [%{child | "profile" => "missing"}],
      [child, %{child | "profile" => "missing", "id" => "other"}],
      [child, child],
      [Map.put(child, "tools", ["write_file"])],
      [Map.put(child, "provider", "untrusted")],
      [child, %{child | "id" => "two"}, %{child | "id" => "three"}]
    ]

    for agents <- invalid do
      assert %Alto.Runner.Result{status: :error, reason: :invalid_team_plan} =
               Alto.run("task",
                 loop:
                   Alto.Contrib.Resident.Team.loop(
                     workers: %{"cheap" => [provider: {CheapProvider, test_pid: self()}]},
                     max_children: 2
                   ),
                 provider: {PlanProvider, plan: JSON.encode!(%{agents: agents})},
                 session: :new,
                 session_dir: dir
               )
    end

    refute_receive {:worker_request, _}, 100
  end

  test "worker names cannot alias a different profile and omitted tools grant none" do
    assert_raise ArgumentError, fn ->
      Alto.Contrib.Resident.Team.loop(
        workers: %{:cheap => [], "cheap" => [tools: [Alto.Contrib.Tools.WriteFile]]}
      )
    end

    loop = Alto.Contrib.Resident.Team.loop(workers: %{"cheap" => []})
    assert loop.driver_options[:workers]["cheap"][:tools] == []
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto_resident-team-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "plans through named worker and integrates child results", %{dir: dir} do
    pid = self()

    journal =
      start_supervised!(
        {Alto.OperationLog, id: "children", name: nil, dir: Path.join(dir, "operations")}
      )

    assert %Alto.Runner.Result{status: :ok} =
             result =
             Alto.run("original task",
               loop:
                 Alto.Contrib.Resident.Team.loop(
                   workers: %{cheap: [provider: {CheapProvider, test_pid: pid}]},
                   max_children: 2,
                   max_concurrency: 1,
                   sessions: :separate
                 ),
               continuation_store: journal,
               provider: {LeadProvider, test_pid: pid},
               prompt: Alto.Contrib.Resident.Team.instructions([:cheap], 2),
               session: :new,
               session_dir: dir
             )

    assert result.output == "integrated"
    assert result.persistence == :ok
    children = Enum.find(result.events, &(&1.type == :subagents_completed)).data.results
    [child] = children
    binding = Enum.find(result.events, &(&1.type == :subagents_completed)).data.journal
    assert {:ok, batch} = Alto.Subagents.Continuation.restore(journal, binding)

    assert {:ok, %{results: [{"worker-1", retained}], packet: %{"join" => nil}}} =
             Alto.Subagents.Continuation.join(batch)

    assert Map.delete(retained, :persistence) == child
    assert retained.persistence == :ok
    assert child.session_id != result.session_id
    assert {:ok, transcript} = Alto.Session.transcript(child.session_id, session_dir: dir)
    assert Enum.any?(transcript["messages"], &(&1["content"] == "finding"))
    refute Enum.any?(transcript["messages"], &(&1["content"] == "original task"))
    assert_receive {:worker_request, worker_request}, 2_000
    assert hd(worker_request.messages)["content"] =~ "Carry out the assigned task"
    refute hd(worker_request.messages)["content"] =~ "Registered profiles"
    assert_receive {:lead_request, %{loop: %{model_tools: []}}}, 2_000
    assert_receive {:lead_request, request}, 2_000

    assert Enum.any?(request.messages, fn message ->
             case JSON.decode(message["content"] || "") do
               {:ok,
                %{
                  "type" => "alto_subagent_results",
                  "results" => [%{"id" => "worker-1", "output" => "finding", "status" => "ok"}]
                }} ->
                 true

               _ ->
                 false
             end
           end)

    assert %Alto.Runner.Result{status: :ok} =
             next =
             Alto.resume(result.session_id, "follow-up task",
               loop:
                 Alto.Contrib.Resident.Team.loop(
                   workers: %{"cheap" => [provider: {CheapProvider, test_pid: pid}]},
                   max_children: 2,
                   max_concurrency: 1
                 ),
               provider: {LeadProvider, test_pid: pid},
               session_dir: dir
             )

    assert next.output == "integrated"
    assert next.session_id == result.session_id
    assert_receive {:worker_request, _}, 2_000
    assert_receive {:lead_request, planning}, 2_000
    assert JSON.decode!(List.last(planning.messages)["content"])["stage"] == "planning"
  end
end
