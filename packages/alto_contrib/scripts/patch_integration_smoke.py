"""Qualify reviewed worker-patch integration across four fresh service VMs."""
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import checkpoint_smoke as service

CONFIG = r'''
defmodule PatchIntegrationSmoke.Writer do
    @behaviour Alto.Loop
    def init(path, spec) do
      File.write!(Path.join(spec.driver_options[:markers], path), "started\n", [:append])

      {:continue, %{}, [
        {:invoke_tool, %{
          name: "write_file",
          arguments: %{"path" => path, "content" => path <> " changed\n"}
        }}
      ]}
    end

    def handle_event(%Alto.Event{type: :tool_completed}, s, _),
      do: {{:stop, :written}, s, []}

    def handle_event(%Alto.Event{type: :tool_failed, data: reason}, s, _),
      do: {{:error, reason}, s, []}

    def handle_event(_, s, _), do: {:continue, s, []}
  end

defmodule PatchIntegrationSmoke.Lead do
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


state = System.fetch_env!("ALTO_RESIDENT_STATE_DIR")
markers = System.fetch_env!("ALTO_RESIDENT_WORKER_MARKERS")
m = Alto.Contrib.Resident.Workspaces.manager(state)
profile = Alto.Config.default(
  provider: PatchIntegrationSmoke.Lead,
  loop: Alto.Contrib.Resident.Team.loop(workspaces: m, max_children: 2, max_concurrency: 2,
    workers: %{writer: [loop: Alto.loop(PatchIntegrationSmoke.Writer, markers: markers), tools: [Alto.Contrib.Tools.WriteFile]]}),
  tools: [Alto.Contrib.Tools.WriteFile, {Alto.Contrib.Resident.Tools.ReviewWorkerPatch, manager: m},
    {Alto.Contrib.Resident.Tools.ApplyWorkerPatch, manager: m}],
  model_tools: [:review_worker_patch, :apply_worker_patch],
  approval: Alto.Contrib.Resident.Approvals.CodingTeam.policy(manager: m),
  checkpoint_version: "coding-team-v1", max_steps: 8, max_effects: 40, max_model_requests: 10)
Alto.Contrib.Resident.Config.new(workspace: System.fetch_env!("ALTO_RESIDENT_WORKSPACE"), state_dir: state,
  profiles: %{"coding" => profile}, scheduling: [workers: 1, max_attempts: 1, poll_ms: 10, run_timeout: 20_000])
'''


def main():
    with tempfile.TemporaryDirectory(prefix="alto-resident-patch-integration-") as temporary:
        base = Path(temporary)
        source, markers = base / "source", base / "markers"
        source.mkdir()
        markers.mkdir()
        for name in ("a", "b"):
            (source / name).write_text(name + "\n")
        env = os.environ.copy()
        env.update(ALTO_RESIDENT_WORKSPACE=str(source), ALTO_RESIDENT_STATE_DIR=str(base / "state"),
                   ALTO_RESIDENT_WORKER_MARKERS=str(markers), ERL_FLAGS="+S 2:2",
                   GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
        for args in [["init", "-q"], ["add", "."],
                     ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base"]]:
            subprocess.run(["git", *args], cwd=source, env=env, check=True,
                           capture_output=True, timeout=15)
        config = base / "service.exs"
        config.write_text(CONFIG)
        socket = str(base / "state/service.sock")
        process = service.launch(env, socket, config)
        try:
            service.command(env, socket, "schedule", "coding", "integrate edits", "--id", "coding")
            pending = service.wait_for(env, socket, "coding", "waiting_approval")
            assert pending["approval"]["tool"] == "apply_worker_patch", pending
            for name in ("a", "b"):
                assert (source / name).read_text() == name + "\n"
            index = (source / ".git/index").read_bytes()
        finally:
            service.stop(process)

        for number, name in enumerate(("a", "b")):
            process = service.launch(env, socket, config)
            try:
                recovered = service.wait_for(env, socket, "coding", "waiting_approval")
                assert recovered["approval"] == pending["approval"], recovered
                assert recovered["revision"] == pending["revision"], recovered
                service.command(env, socket, "task-decide", "coding", "approve",
                                "--revision", str(recovered["revision"]))
                if number == 0:
                    deadline = time.monotonic() + 20
                    while True:
                        current = service.task(env, socket, "coding")
                        if current["status"] == "waiting_approval" and current["revision"] != pending["revision"]:
                            pending = current
                            break
                        if time.monotonic() > deadline:
                            raise AssertionError(current)
                        time.sleep(0.025)
                else:
                    service.wait_for(env, socket, "coding", "completed")
                assert (source / name).read_text() == name + " changed\n"
                assert (source / ".git/index").read_bytes() == index
                for worker in ("a", "b"):
                    assert (markers / worker).read_text() == "started\n"
            finally:
                service.stop(process)

        process = service.launch(env, socket, config)
        try:
            service.wait_for(env, socket, "coding", "completed")
            resources = service.command(env, socket, "workspaces")[-1]["workspaces"]
            assert len(resources) == 2 and all(r["status"] == "applied" for r in resources), resources
            for resource in resources:
                service.command(env, socket, "workspace-discard", resource["id"],
                                "--revision", str(resource["revision"]), "--note", "integrated")
            for worker in ("a", "b"):
                assert (markers / worker).read_text() == "started\n"
                assert (source / worker).read_text() == worker + " changed\n"
        finally:
            service.stop(process)
        print("PASS: two coding workers, two exact durable patch approvals, four fresh VMs, unchanged index and no worker replay")


if __name__ == "__main__":
    if len(sys.argv) == 2:
        service.EXECUTABLE = str(Path(sys.argv[1]).resolve())
    elif len(sys.argv) != 1:
        raise SystemExit("Usage: patch_integration_smoke.py [ALTO_RESIDENT_CLI]")
    main()
