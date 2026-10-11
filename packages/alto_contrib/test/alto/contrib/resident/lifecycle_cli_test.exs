defmodule Alto.Contrib.Resident.LifecycleCLITest do
  use ExUnit.Case, async: true

  alias Alto.Contrib.Resident.CLI

  test "child approval requires every fenced identity" do
    assert {:error, :invalid_task_child_decide} =
             CLI.run(["task-child-decide", "task", "child", "approve"])

    assert {:error, :invalid_task_child_decide} =
             CLI.run([
               "task-child-decide",
               "task",
               "child",
               "approve",
               "--revision",
               "1",
               "--batch-revision",
               "1",
               "--generation",
               "g",
               "--attempt",
               "a",
               "--suspension",
               "s",
               "--key",
               ""
             ])
  end

  test "child approval rejects invalid decision and revisions" do
    assert {:error, {:invalid_task_child_decide, :decision}} =
             CLI.run(["task-child-decide", "task", "child", "maybe"])

    args = [
      "task-child-decide",
      "task",
      "child",
      "approve",
      "--revision",
      "0",
      "--batch-revision",
      "1",
      "--generation",
      "g",
      "--attempt",
      "a",
      "--suspension",
      "s",
      "--key",
      "k"
    ]

    assert {:error, :invalid_task_child_decide} = CLI.run(args)
  end

  test "cleanup requires a positive task revision and never opens a socket" do
    assert {:error, :task_cleanup_requires_revision} = CLI.run(["task-cleanup", "task"])

    assert {:error, :task_cleanup_requires_revision} =
             CLI.run(["task-cleanup", "task", "--revision", "-1"])
  end

  test "team child approval inspection requires generation and revision" do
    assert {:error, :team_child_approval_requires_generation_and_revision} =
             CLI.run(["team-child-approval", "key", "child"])

    assert {:error, :team_child_approval_requires_generation_and_revision} =
             CLI.run([
               "team-child-approval",
               "key",
               "child",
               "--generation",
               "",
               "--revision",
               "1"
             ])
  end
end
