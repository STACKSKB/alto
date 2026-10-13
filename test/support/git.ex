defmodule Alto.TestSupport.Git do
  @moduledoc false

  # Fixture commits should not depend on the host's identity, hooks or signing setup.
  def git!(cwd, args) do
    config = [
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "-c",
      "commit.gpgsign=false"
    ]

    case System.cmd("git", config ++ args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> ExUnit.Assertions.flunk("git failed #{status}: #{output}")
    end
  end
end
