"""Resume a killed parent's retained child batch through the resident CLI."""

import os
import signal
import tempfile
import time
from pathlib import Path

import checkpoint_smoke as service


CONFIG = r'''
defmodule ParentRecoverySmoke.Runner do
  @behaviour Alto.Runner
  def run(task, opts) do
    if Keyword.get(opts, :agent_depth, 0) == 0,
      do: Process.register(self(), ParentRecoverySmoke.Parent)
    runner = case System.fetch_env!("ALTO_RESIDENT_SMOKE_RUNNER") do
      "serial" -> Alto.Runner.Serial
      other -> raise ArgumentError, "unsupported runner: #{inspect(other)}"
    end
    runner.run(task, opts)
  end
  def start(task, opts), do: Alto.Runner.TaskHost.start(fn ref ->
    run(task, Keyword.put(opts, :cancel_ref, ref)) end, opts)
  defdelegate await(handle, timeout), to: Alto.Runner.TaskHost
  defdelegate cancel(handle, reason), to: Alto.Runner.TaskHost
  defdelegate terminate(handle, reason), to: Alto.Runner.TaskHost
  defdelegate subscribe(handle, pid), to: Alto.Runner.TaskHost
end
defmodule ParentRecoverySmoke.Lead do
  @behaviour Alto.Provider
  def describe(_), do: %{}
  def stream(request, _, _) do
    cond do
      Enum.any?(request.messages, &(&1["role"] == "tool")) ->
        {:ok, %{message: "integrated", tool_calls: []}}
      Enum.any?(request.messages, &(is_binary(&1["content"]) and
        String.contains?(&1["content"], "alto_subagent_results"))) ->
        {:ok, %{message: nil, tool_calls: [%{id: "integration", name: "effect",
          arguments_json: ~s({"id":"integrated"})}]}}
      true ->
        File.write!(Path.join(System.fetch_env!("ALTO_RESIDENT_WORKSPACE"), "plans"), "1", [:append])
        {:ok, %{message: ~s({"agents":[{"id":"worker","profile":"worker","task":"worker"}]}),
          tool_calls: []}}
    end
  end
end
defmodule ParentRecoverySmoke.Worker do
  @behaviour Alto.Loop
  def init(task, _), do: {:continue, %{}, [{:invoke_tool, %{
    name: "effect", arguments: %{"id" => task}}}]}
  def handle_event(%Alto.Event{type: :tool_completed}, state, _),
    do: {{:stop, "exact retained worker finding"}, state, []}
  def handle_event(event, state, _), do: {{:error, event.type}, state, []}
end
defmodule ParentRecoverySmoke.Effect do
  @behaviour Alto.Tool
  def name(_opts), do: :effect
  def schema(_opts), do: %{description: "fixture effect", parameters: %{type: "object", properties: %{}}}
  def execution_mode(_opts), do: :exclusive
  def approval(_opts), do: :never
  def run(%{"id" => id}, context, _opts) do
    File.write!(Path.join(context.cwd, id), "1", [:append])
    # Suspend collection only, allowing the worker to persist its exact result.
    if id == "worker" do
      caller = self()
      spawn(fn ->
        :erlang.suspend_process(Process.whereis(ParentRecoverySmoke.Parent))
        send(caller, :parent_frozen)
        receive do :release -> :ok end
      end)
      receive do :parent_frozen -> :ok after 2000 -> raise "parent was not frozen" end
    end
    {:ok, id}
  end
end
profile = Alto.Config.default(
  runner: ParentRecoverySmoke.Runner, runner_options: [mode: :automatic],
  provider: ParentRecoverySmoke.Lead, continuation_store: Alto.Contrib.Resident.ParentRuns.ledger(),
  checkpoint_version: "parent-recovery-smoke-v1",
  loop: Alto.Contrib.Resident.Team.loop(workers: %{"worker" => [loop: Alto.loop(ParentRecoverySmoke.Worker),
    tools: [ParentRecoverySmoke.Effect]]}, max_children: 1, max_concurrency: 1,
    sessions: :separate),
  tools: [ParentRecoverySmoke.Effect], approval: {:deny, :policy_denied})
Alto.Contrib.Resident.Config.new(workspace: System.fetch_env!("ALTO_RESIDENT_WORKSPACE"),
  state_dir: System.fetch_env!("ALTO_RESIDENT_STATE_DIR"),
  scheduling: [workers: 1, poll_ms: 10, run_timeout: 180_000], profiles: %{"team" => profile})
'''


def main(runner="serial"):
    with tempfile.TemporaryDirectory(prefix="zek-parent-recovery-") as temporary:
        base = Path(temporary)
        workspace = base / "workspace"
        workspace.mkdir()
        state = base / "state"
        socket_path = str(state / "service.sock")
        config = base / "service.exs"
        config.write_text(CONFIG)
        environment = os.environ.copy()
        environment.update(ALTO_RESIDENT_WORKSPACE=str(workspace), ALTO_RESIDENT_STATE_DIR=str(state),
                           ALTO_RESIDENT_SMOKE_RUNNER=runner, ERL_FLAGS="+S 2:2")
        process = service.launch(environment, socket_path, config)
        try:
            service.command(environment, socket_path, "schedule", "team", "delegate and integrate",
                            "--id", "parent")
            deadline = time.monotonic() + 20
            while True:
                batches = service.command(environment, socket_path, "team-batches")[-1]["batches"]
                if batches and batches[0]["counts"] == {"completed": 1}:
                    break
                assert time.monotonic() < deadline, batches
                time.sleep(0.05)
            assert not (workspace / "integrated").exists()
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=10)
        finally:
            service.stop(process)

        process = service.launch(environment, socket_path, config)
        try:
            parked = service.wait_for(environment, socket_path, "parent", "requires_operator")
            continuation = parked["parent_continuation"]
            assert continuation["phase"] == "children", parked
            identity = continuation["identity"]
            response = service.command(environment, socket_path, "task-recover", "parent",
                                       identity["key"], "--revision", str(parked["revision"]),
                                       "--generation", identity["generation"],
                                       "--continuation-revision", str(continuation["revision"]))[-1]
            assert response["type"] == "ok", response
            completed = service.wait_for(environment, socket_path, "parent", "completed")
            assert completed["session_id"] == continuation["session_id"], completed
            assert (workspace / "plans").read_text() == "1"
            assert (workspace / "worker").read_text() == "1"
            assert (workspace / "integrated").read_text() == "1"
        finally:
            service.stop(process)

        process = service.launch(environment, socket_path, config)
        try:
            assert service.task(environment, socket_path, "parent")["status"] == "completed"
            assert (workspace / "plans").read_text() == "1"
            assert (workspace / "worker").read_text() == "1"
            assert (workspace / "integrated").read_text() == "1"
            batch, = service.command(environment, socket_path, "team-batches")[-1]["batches"]
            assert batch["joined"]
        finally:
            service.stop(process)
    print(f"PASS ({runner}): exact parent continuation across three VMs, one plan, one child, "
          "one integration effect and a claimed aggregate")


if __name__ == "__main__":
    main()
