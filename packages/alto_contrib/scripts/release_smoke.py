"""Qualify a built release archive without system Erlang/Elixir or a checkout.

Usage: python3 scripts/release_smoke.py _build/prod/alto-0.0.2.tar.gz
Only temporary files and processes are created; no service is installed.
"""

import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

import checkpoint_smoke
import child_suspension_smoke
import team_child_suspension_smoke
import patch_integration_smoke
import parent_recovery_smoke


def check_private(state):
    for path in [state, *state.rglob("*")]:
        assert stat.S_IMODE(path.stat().st_mode) & 0o077 == 0, path


def interrupted_run(base):
    """Kill after an external effect, then prove restart parks the attempt."""
    workspace = base / "interrupted-workspace"
    workspace.mkdir()
    state = base / "interrupted-state"
    socket_path = str(state / "service.sock")
    config = base / "interrupted-config.exs"
    config.write_text('''
defmodule ReleaseSmoke.Echo do
  @behaviour Alto.Tool
  def name(_opts), do: :echo
  def schema(_opts), do: %{description: "echo", parameters: %{type: "object", properties: %{}}}
  def approval(_opts), do: :never
  def execution_mode(_opts), do: :exclusive
  def run(arguments, _context, _opts), do: {:ok, arguments}
end
defmodule ReleaseSmoke.Effect do
  @behaviour Alto.Tool
  def name(_opts), do: :effect
  def schema(_opts), do: %{description: "effect", parameters: %{type: "object", properties: %{}}}
  def approval(_opts), do: :never
  def execution_mode(_opts), do: :exclusive
  def run(_, context, _opts) do
    File.write!(Path.join(context.cwd, "effect"), "1", [:append])
    Process.sleep(60_000)
    {:ok, "done"}
  end
end
Alto.Contrib.Resident.Config.new(
  workspace: System.fetch_env!("ALTO_RESIDENT_WORKSPACE"),
  state_dir: System.fetch_env!("ALTO_RESIDENT_STATE_DIR"),
  scheduling: [workers: 1, poll_ms: 10, run_timeout: 120_000],
  profiles: %{"echo" => Alto.Config.default(
    provider: nil, loop: Alto.rule_loop(steps: ["echo"]),
    tools: [ReleaseSmoke.Echo], approval: {:deny, :policy_denied}
  ), "effect" => Alto.Config.default(
    provider: nil, loop: Alto.rule_loop(steps: ["effect"]),
    tools: [ReleaseSmoke.Effect], approval: {:deny, :policy_denied}
  )}
)
''')
    environment = os.environ.copy()
    environment.update(ALTO_RESIDENT_WORKSPACE=str(workspace), ALTO_RESIDENT_STATE_DIR=str(state))
    process = checkpoint_smoke.launch(environment, socket_path, config)
    try:
        payload = {"text": "spaces 'quotes' \"$HOME\"; $(touch injected); `touch injected`\nline two"}
        started = checkpoint_smoke.command(environment, socket_path, "start", "echo",
                                           json.dumps(payload, indent=2))[-1]
        result = checkpoint_smoke.command(environment, socket_path, "watch", started["run_id"])[-1]
        assert result["status"] == "ok" and result["output"] == [payload], result
        assert not (base / "injected").exists(), "Task text was evaluated by a shell"
        # A second service must not take ownership of the same durable state.
        duplicate = subprocess.run(
            [checkpoint_smoke.EXECUTABLE, "serve", str(config)],
            env=environment, capture_output=True, timeout=15,
        )
        assert duplicate.returncode != 0, duplicate.stdout
        checkpoint_smoke.command(environment, socket_path, "schedule", "effect", "{}",
                                 "--id", "interrupted")
        deadline = time.monotonic() + 15
        while not (workspace / "effect").exists():
            assert process.poll() is None, "Service exited before the effect"
            assert time.monotonic() < deadline, "Effect was not dispatched"
            time.sleep(0.025)
        assert (workspace / "effect").read_text() == "1"
        # Terminate the whole group, as systemd's KillMode=control-group would.
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=10)
    finally:
        checkpoint_smoke.stop(process)

    process = checkpoint_smoke.launch(environment, socket_path, config)
    try:
        current = checkpoint_smoke.wait_for(environment, socket_path, "interrupted", "requires_operator")
        assert current["revision"] > 0, current
        assert (workspace / "effect").read_text() == "1"
        check_private(state)
        # Send SIGTERM to the main PID only: the launcher must exec the VM.
        process.terminate()
        process.communicate(timeout=10)
        assert not Path(socket_path).exists(), "Orderly shutdown left the listener socket"
    finally:
        checkpoint_smoke.stop(process)

    process = checkpoint_smoke.launch(environment, socket_path, config)
    try:
        again = checkpoint_smoke.task(environment, socket_path, "interrupted")
        assert again["status"] == "requires_operator", again
        assert (workspace / "effect").read_text() == "1"
    finally:
        checkpoint_smoke.stop(process)


def main(archive):
    archive = Path(archive).resolve(strict=True)
    previous_env = os.environ.copy()
    previous_cwd = Path.cwd()
    with tempfile.TemporaryDirectory(prefix="alto-resident-release-") as temporary:
        base = Path(temporary)
        # Spaces exercise shell quoting and relocation in the generated launchers.
        release = base / "installed release"
        release.mkdir()
        with tarfile.open(archive) as bundle:
            bundle.extractall(release, filter="data")
        assert list(release.glob("erts-*/bin/beam.smp")), "Missing bundled runtime"
        assert not list((release / "lib").glob("ex_ratatui*")), "Native UI in service bundle"
        assert not (release / "mix.exs").exists(), "Service unexpectedly needs a checkout"
        for required in ["deploy/alto-resident", "deploy/alto-resident.service",
                         "examples/resident/alto.exs", "examples/resident/coding-team.exs",
                         "docs/resident-service.md"]:
            assert (release / required).is_file(), f"Missing packaged file: {required}"

        # Only OS utilities needed by the generated scripts and Alto's lock helper.
        utilities = base / "utilities"
        utilities.mkdir()
        for name in ["sh", "dirname", "basename", "readlink", "cut", "sed", "cat",
                     "grep", "flock", "git", "env", "sync", "kill"]:
            target = shutil.which(name)
            assert target, f"Missing system utility: {name}"
            (utilities / name).symlink_to(target)
        launcher = str(release / "deploy/alto-resident")
        try:
            os.environ["PATH"] = str(utilities)
            os.environ["ERL_FLAGS"] = "+S 2:2"
            for key in list(os.environ):
                if key.startswith(("RELEASE_", "MIX_", "ALTO_")):
                    del os.environ[key]
            os.chdir(base)
            assert shutil.which("erl") is None and shutil.which("elixir") is None
            assert shutil.which("mix") is None
            bad = subprocess.run([launcher, "serve", str(base / "missing.exs")],
                                 capture_output=True, text=True, timeout=15)
            assert bad.returncode != 0 and "config_load_failed" in bad.stderr, bad

            checkpoint_smoke.EXECUTABLE = launcher
            checkpoint_smoke.main()
            parent_recovery_smoke.main()
            child_suspension_smoke.main()
            team_child_suspension_smoke.main()
            patch_integration_smoke.main()
            interrupted_run(base)
        finally:
            os.chdir(previous_cwd)
            os.environ.clear()
            os.environ.update(previous_env)
    print("PASS: relocated bundled runtime, startup failures, exclusive state ownership, "
          "SIGTERM cleanup, crash review, private state, scheduling and approval recovery")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: release_smoke.py RELEASE.tar.gz")
    main(sys.argv[1])
