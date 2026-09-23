defmodule Alto.External.ClientOptionsTest do
  use ExUnit.Case, async: true

  @clients [Alto.External.MCP.Client, Alto.Codex.AppServer.Client]

  test "clients report unavailable commands and directories at the same boundary" do
    for client <- @clients do
      assert {:error, :empty_external_command} = client.ensure_started(command: "")

      assert {:error, {:external_executable_not_found, "alto-no-such-executable"}} =
               client.ensure_started(command: "alto-no-such-executable")

      assert {:error, {:invalid_working_directory, "/alto-no-such-directory"}} =
               client.ensure_started(
                 command: System.find_executable("sh"),
                 cwd: "/alto-no-such-directory"
               )
    end
  end
end
