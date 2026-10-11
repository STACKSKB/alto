defmodule Alto.Contrib.Resident.WorkerPatchCheckpointTest do
  use ExUnit.Case, async: false
  alias Alto.Contrib.Resident.{Config, Service, Tasks, Workspaces}

  defmodule Writer do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _, opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        {:ok, %{message: "written", tool_calls: [], usage: %{input_tokens: 1, output_tokens: 1}}}
      else
        path = Enum.find(request.messages, &(&1["role"] == "user"))["content"]
        send(opts[:test_pid], {:worker_started, path})

        {:ok,
         %{
           message: nil,
           tool_calls: [
             %{
               id: "write",
               name: "write_file",
               arguments_json: JSON.encode!(%{"path" => path, "content" => path <> " changed\n"})
             }
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end
    end
  end

  defmodule Lead do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _, _) do
      resources =
        Enum.find_value(request.messages, fn message ->
          case JSON.decode(message["content"] || "") do
            {:ok, %{"type" => "alto_subagent_results", "results" => results}} ->
              Enum.map(results, & &1["workspace"])

            _ ->
              nil
          end
        end)

      count = Enum.count(request.messages, &(&1["role"] == "tool"))

      completion =
        cond do
          is_nil(resources) ->
            %{
              message:
                JSON.encode!(%{
                  agents: [
                    %{id: "a", profile: "writer", task: "a"},
                    %{id: "b", profile: "writer", task: "b"}
                  ]
                }),
              tool_calls: []
            }

          count == 4 ->
            %{message: "integrated", tool_calls: []}

          true ->
            ws = Enum.at(resources, div(count, 2))
            args = %{"workspace_id" => ws["id"]}

            {tool, args} =
              if rem(count, 2) == 0,
                do: {"review_worker_patch", args},
                else: {"apply_worker_patch", Map.put(args, "revision", ws["revision"])}

            %{
              message: nil,
              tool_calls: [
                %{id: "integration-#{count}", name: tool, arguments_json: JSON.encode!(args)}
              ]
            }
        end

      {:ok, Map.put(completion, :usage, %{input_tokens: 1, output_tokens: 1})}
    end
  end

  test "named coding workers integrate through repeated durable approvals without replay" do
    dir =
      Path.join(System.tmp_dir!(), "zek-patch-checkpoint-#{System.unique_integer([:positive])}")

    source = Path.join(dir, "source")
    state = Path.join(dir, "state")
    File.mkdir_p!(source)
    on_exit(fn -> File.rm_rf!(dir) end)
    for f <- ["a", "b"], do: File.write!(Path.join(source, f), f <> "\n")
    git!(source, ["init", "-q"])
    git!(source, ["add", "."])

    git!(source, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "-qm",
      "base"
    ])

    name = make_ref()
    m = Workspaces.manager(state, name)

    profile =
      Alto.Config.default(
        provider: Lead,
        loop:
          Alto.Contrib.Resident.Team.loop(
            workspaces: m,
            max_children: 2,
            max_concurrency: 2,
            workers: %{
              writer: [
                provider: {Writer, test_pid: self()},
                tools: [Alto.Contrib.Tools.WriteFile]
              ]
            }
          ),
        tools: [
          Alto.Contrib.Tools.WriteFile,
          {Alto.Contrib.Resident.Tools.ReviewWorkerPatch, manager: m},
          {Alto.Contrib.Resident.Tools.ApplyWorkerPatch, manager: m}
        ],
        model_tools: [:write_file, :review_worker_patch, :apply_worker_patch],
        approval: Alto.Contrib.Resident.Approvals.CodingTeam.policy(manager: m),
        checkpoint_version: "coding-team-v1",
        max_steps: 8,
        max_effects: 40,
        max_model_requests: 10
      )

    config =
      Config.new(
        workspace: source,
        state_dir: state,
        profiles: %{"coding" => profile},
        scheduling: [workers: 1, max_attempts: 1, poll_ms: 10, run_timeout: 20_000]
      )

    start_supervised!({Service, name: name, config: config})

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "integrate",
               "profile" => "coding",
               "task" => "make edits"
             })

    first = wait_for(name, "waiting_approval")
    assert first["approval"]["tool"] == "apply_worker_patch"
    assert_receive {:worker_started, "a"}, 2_000
    assert_receive {:worker_started, "b"}, 2_000
    assert File.read!(Path.join(source, "a")) == "a\n"
    assert File.read!(Path.join(source, "b")) == "b\n"
    index = File.read!(Path.join(source, ".git/index"))
    stop_supervised!(Service)
    start_supervised!({Service, name: name, config: config})
    recovered = wait_for(name, "waiting_approval")
    assert recovered["approval"] == first["approval"]
    decide(name, recovered)
    second = wait_for(name, "waiting_approval", first["revision"])
    assert File.read!(Path.join(source, "a")) == "a changed\n"
    assert File.read!(Path.join(source, "b")) == "b\n"
    stop_supervised!(Service)
    start_supervised!({Service, name: name, config: config})
    assert wait_for(name, "waiting_approval")["approval"] == second["approval"]
    decide(name, second)
    completed = wait_for(name, "completed")
    assert completed["session_id"] == first["session_id"]
    assert File.read!(Path.join(source, "b")) == "b changed\n"
    assert File.read!(Path.join(source, ".git/index")) == index
    refute_receive {:worker_started, _}, 100

    for id <-
          Alto.OperationLog.request(m.ledger, {:entries, :all}) |> Enum.map(& &1.operation_key) do
      assert {:ok, %{status: "applied"}} = Alto.Contrib.Workspaces.get(m, id)
    end
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end

  defp decide(name, task) do
    assert {:ok, _} =
             Tasks.command(name, "decide", %{
               "id" => "integrate",
               "revision" => task["revision"],
               "decision" => "approve"
             })
  end

  defp wait_for(name, status, old_revision \\ nil) do
    wait(name, status, old_revision, System.monotonic_time(:millisecond) + 20_000)
  end

  defp wait(name, status, old_revision, deadline) do
    result = Tasks.command(name, "get", %{"id" => "integrate"})

    case result do
      {:ok, %{"task" => %{"status" => ^status, "revision" => revision} = task}}
      when revision != old_revision ->
        task

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          wait(name, status, old_revision, deadline)
        else
          flunk("expected #{status}: #{inspect(result)}")
        end
    end
  end
end
