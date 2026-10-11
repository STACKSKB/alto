"""Exercise durable approval checkpoints across independent service VMs."""

import json
import os
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
EXECUTABLE = os.environ.get("ALTO_RESIDENT_EXECUTABLE", str(ROOT / "deploy/alto-resident"))


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
    process.communicate(timeout=10)


def launch(environment, socket_path, config_path):
    process = subprocess.Popen(
        [EXECUTABLE, "serve", str(config_path)],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    deadline = time.monotonic() + 15
    try:
        while True:
            if process.poll() is not None:
                raise RuntimeError(process.communicate())
            try:
                with socket.socket(socket.AF_UNIX) as probe:
                    probe.settimeout(0.2)
                    probe.connect(socket_path)
                    if probe.recv(4096):
                        return process
            except (FileNotFoundError, ConnectionRefusedError, socket.timeout):
                pass
            if time.monotonic() > deadline:
                raise RuntimeError("Service did not become ready")
            time.sleep(0.025)
    except BaseException:
        stop(process)
        raise


def command(environment, socket_path, *arguments):
    result = subprocess.run(
        [EXECUTABLE, *arguments, "--socket", socket_path],
        env=environment,
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)
    return [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]


def task(environment, socket_path, task_id):
    return command(environment, socket_path, "task", task_id)[-1]["task"]


def wait_for(environment, socket_path, task_id, status, timeout=20):
    deadline = time.monotonic() + timeout
    while True:
        current = task(environment, socket_path, task_id)
        if current["status"] == status:
            return current
        if time.monotonic() >= deadline:
            raise AssertionError(f"{task_id} did not become {status}: {current}")
        time.sleep(0.1)


def write_config(path):
    path.write_text(
        '''
defmodule CheckpointSmoke.FirstTool do
  @behaviour Alto.Tool
  def name(_opts), do: :first
  def schema(_opts), do: %{description: "first", parameters: %{type: "object", properties: %{}}}
  def execution_mode(_opts), do: :exclusive
  def approval(_opts), do: :never
  def run(_, context, _opts) do
    File.write!(Path.join(context.cwd, "first"), "1", [:append])
    {:ok, "first"}
  end
end

defmodule CheckpointSmoke.GuardedTool do
  @behaviour Alto.Tool
  def name(_opts), do: :guarded
  def schema(_opts), do: %{description: "guarded", parameters: %{type: "object", properties: %{}}}
  def execution_mode(_opts), do: :exclusive
  def approval(_opts), do: :required
  def prepare(_, context, _opts) do
    value = File.read!(Path.join(context.cwd, "input"))
    File.write!(Path.join(context.cwd, "prepared"), value)
    {:ok, %{value: value}, %{action: "append saved input"}}
  end
  def run(%{value: value}, context, _opts) do
    File.write!(Path.join(context.cwd, "approved"), value, [:append])
    {:ok, value}
  end
end

runner = case System.get_env("ALTO_RESIDENT_SMOKE_RUNNER", "serial") do
  "serial" -> Alto.Runner.Serial
  other -> raise ArgumentError, "unsupported runner: #{inspect(other)}"
end
profile = fn steps, approval ->
  Alto.Config.default(
    runner: runner,
    runner_options: [],
    provider: nil,
    loop: Alto.rule_loop(steps: steps),
    tools: [CheckpointSmoke.FirstTool, CheckpointSmoke.GuardedTool],
    approval: approval,
    checkpoint_version: "smoke-v1"
  )
end

Alto.Contrib.Resident.Config.new(
  workspace: System.fetch_env!("ALTO_RESIDENT_WORKSPACE"),
  state_dir: System.fetch_env!("ALTO_RESIDENT_STATE_DIR"),
  scheduling: [workers: 1, max_attempts: 1, poll_ms: 10, run_timeout: 5_000],
  profiles: %{
    "guarded" => profile.( ["first", "guarded"], :suspend),
    "safe" => profile.( ["first"], {:deny, :policy_denied})
  }
)
'''
    )


def main(runner="serial", resume_runner=None):
    with tempfile.TemporaryDirectory(prefix="alto-resident-checkpoint-") as temporary:
        base = Path(temporary)
        workspace = base / "workspace"
        workspace.mkdir()
        (workspace / "input").write_text("original")
        state = base / "state"
        socket_path = str(state / "service.sock")
        config_path = base / "config.exs"
        write_config(config_path)
        environment = os.environ.copy()
        environment.update(
            ALTO_RESIDENT_WORKSPACE=str(workspace),
            ALTO_RESIDENT_STATE_DIR=str(state),
            ERL_FLAGS="+S 2:2",
            ALTO_RESIDENT_SMOKE_RUNNER=runner,
        )

        process = launch(environment, socket_path, config_path)
        try:
            queued = command(environment, socket_path, "schedule", "guarded", "{}", "--id", "approval")[-1]
            assert queued["status"] == "queued", queued
            pending = wait_for(environment, socket_path, "approval", "waiting_approval")
            assert pending["approval"]["tool"] == "guarded", pending
            approval = pending["approval"]
            revision = pending["revision"]
            assert (workspace / "first").read_text() == "1"
            assert not (workspace / "approved").exists()
            command(environment, socket_path, "schedule", "safe", "{}", "--id", "safe")
            wait_for(environment, socket_path, "safe", "completed")
            assert (workspace / "first").read_text() == "11"
        finally:
            stop(process)

        (workspace / "input").write_text("changed")
        environment["ALTO_RESIDENT_SMOKE_RUNNER"] = resume_runner or runner
        process = launch(environment, socket_path, config_path)
        try:
            recovered = wait_for(environment, socket_path, "approval", "waiting_approval")
            assert recovered["approval"] == approval, (approval, recovered)
            assert recovered["revision"] == revision, recovered
            decided = command(
                environment,
                socket_path,
                "task-decide",
                "approval",
                "approve",
                "--revision",
                str(revision),
            )[-1]
            assert decided["task_id"] == "approval", decided
            assert decided["revision"] > revision, decided
            wait_for(environment, socket_path, "approval", "completed")
            assert (workspace / "approved").read_text() == "original"
            assert (workspace / "prepared").read_text() == "original"
            assert (workspace / "first").read_text() == "11"
        finally:
            stop(process)

        process = launch(environment, socket_path, config_path)
        try:
            completed = task(environment, socket_path, "approval")
            assert completed["status"] == "completed", completed
            assert (workspace / "approved").read_text() == "original"
            assert (workspace / "first").read_text() == "11"
        finally:
            stop(process)

    print(f"PASS: durable approval checkpoint, freed worker, exact prepared value, fresh-VM recovery ({runner} -> {resume_runner or runner})")


if __name__ == "__main__":
    main()
