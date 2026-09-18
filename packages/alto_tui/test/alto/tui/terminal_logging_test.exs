defmodule Alto.TUI.TerminalLoggingTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag skip: match?({:win32, _}, :os.type()) or is_nil(System.find_executable("python3"))

  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
  end

  for scenario <- ["normal", "crash", "startup_failure", "owner_exit"] do
    @tag timeout: 30_000
    test "real terminal keeps logs out of frames and restores logging after #{scenario}", %{
      tmp_dir: root
    } do
      scenario = unquote(scenario)
      support = Path.expand("../../support", __DIR__)

      {output, status} =
        System.cmd(
          System.find_executable("python3"),
          [
            Path.join(support, "tui_pty.py"),
            System.find_executable("elixir"),
            "--erl",
            "+S 2:2",
            "-pa",
            Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]),
            Path.join(support, "tui_logging_fixture.exs"),
            root,
            scenario
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert [_, terminal] = String.split(output, "\e[?1049h", parts: 2)
      assert [frame, after_terminal] = String.split(terminal, "\e[?1049l", parts: 2)
      refute frame =~ "MUST_STAY_IN_FILE"
      refute frame =~ "[warning]"
      refute frame =~ "[error]"
      assert after_terminal =~ "TUI_CONSOLE_RESTORED"

      if scenario != "startup_failure" do
        assert frame =~ "Welcome to Alto"
        log = File.read!(Path.join(root, "tui.log"))
        assert log =~ "TUI_DEBUG_MUST_STAY_IN_FILE"
        assert log =~ "TUI_WARNING_MUST_STAY_IN_FILE"
        assert log =~ "TUI_ERROR_MUST_STAY_IN_FILE"
      end
    end
  end
end
