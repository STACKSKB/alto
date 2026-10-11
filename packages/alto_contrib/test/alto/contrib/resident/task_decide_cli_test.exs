defmodule Alto.Contrib.Resident.TaskDecideCLITest do
  use ExUnit.Case, async: true

  alias Alto.Contrib.Resident.CLI

  test "task-decide requires a positive revision" do
    assert {:error, {:invalid_task_decide, :revision}} =
             CLI.run(["task-decide", "task-1", "approve", "--revision", "0"])
  end

  test "task-decide accepts only approve or deny" do
    assert {:error, {:invalid_task_decide, :decision}} =
             CLI.run(["task-decide", "task-1", "retry", "--revision", "1"])
  end
end
