defmodule Alto.Contrib.Resident.TeamCheckpointTest do
  use ExUnit.Case, async: false

  alias Alto.Contrib.Resident.{Config, Service, Tasks}

  defmodule LeadProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:test_pid], {:lead_request, request})

      {:ok, completion} =
        cond do
          Enum.any?(request.messages, &(&1["role"] == "tool")) ->
            {:ok, %{message: "done", tool_calls: []}}

          Enum.any?(request.messages, fn message ->
            message["role"] == "user" and is_binary(message["content"]) and
                String.contains?(message["content"], "alto_subagent_results")
          end) ->
            {:ok,
             %{
               message: nil,
               tool_calls: [%{id: "guard-1", name: "guarded", arguments_json: "{}"}]
             }}

          true ->
            {:ok,
             %{
               message:
                 ~s({"agents":[{"id":"a","profile":"cheap","task":"one"},{"id":"b","profile":"cheap","task":"two"}]}),
               tool_calls: []
             }}
        end

      {:ok, Map.put(completion, :usage, %{input_tokens: 1, output_tokens: 1})}
    end
  end

  defmodule CheapProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:test_pid], {:cheap_request, request})
      {:ok, %{message: "finding", tool_calls: [], usage: %{input_tokens: 1, output_tokens: 1}}}
    end
  end

  defmodule Guarded do
    @behaviour Alto.Tool
    def name(_opts), do: :guarded

    def schema(_opts),
      do: %{description: "Append file1", parameters: %{type: "object", properties: %{}}}

    def execution_mode(_opts), do: :exclusive
    def approval(_opts), do: :required
    def prepare(%{}, _context, _opts), do: {:ok, %{}, %{action: "append file1"}}

    def run(%{}, context, _opts) do
      File.write!(Path.join(context.cwd, "file1"), "effect\n", [:append])
      {:ok, "effect"}
    end
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "zek-team-checkpoint-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "resident team integration resumes exact approval continuation", %{dir: dir} do
    pid = self()

    profile =
      Alto.Config.default(
        provider: {LeadProvider, test_pid: pid},
        loop:
          Alto.Contrib.Resident.Team.loop(
            workers: %{cheap: [provider: {CheapProvider, test_pid: pid}, max_steps: 1]},
            max_children: 2,
            max_concurrency: 2
          ),
        tools: [Guarded],
        model_tools: [:guarded],
        approval: :suspend,
        checkpoint_version: "team-v1",
        max_steps: 3,
        max_effects: 20,
        max_model_requests: 5
      )

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        scheduling: [workers: 1, max_attempts: 1, poll_ms: 10, run_timeout: 10_000],
        profiles: %{"team" => profile}
      )

    name = make_ref()
    start_supervised!({Service, name: name, config: config})

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "team-1",
               "profile" => "team",
               "task" => "work"
             })

    waiting = wait_for(name, "team-1", "waiting_approval")
    assert is_binary(waiting["session_id"])
    assert waiting["usage"]["total_tokens"] == 8
    assert_receive {:cheap_request, _}, 2_000
    assert_receive {:cheap_request, _}, 2_000
    refute_receive {:cheap_request, _}, 100

    stop_supervised!(Service)
    start_supervised!({Service, name: name, config: config})
    recovered = wait_for(name, "team-1", "waiting_approval")
    assert recovered["revision"] == waiting["revision"]

    assert {:ok, _} =
             Tasks.command(name, "decide", %{
               "id" => "team-1",
               "revision" => recovered["revision"],
               "decision" => "approve"
             })

    completed = wait_for(name, "team-1", "completed")
    assert completed["session_id"] == waiting["session_id"]
    assert completed["usage"]["total_tokens"] == 10
    assert File.read!(Path.join(dir, "file1")) == "effect\n"
    refute_receive {:cheap_request, _}, 200
  end

  defp wait_for(name, id, status) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_wait(name, id, status, deadline)
  end

  defp do_wait(name, id, status, deadline) do
    case Tasks.command(name, "get", %{"id" => id}) do
      {:ok, %{"task" => %{"status" => ^status} = task}} ->
        task

      other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          do_wait(name, id, status, deadline)
        else
          flunk("expected #{status}, got #{inspect(other)}")
        end
    end
  end
end
