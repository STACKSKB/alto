defmodule Alto.TUI.TerminalLoggingTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag skip: match?({:win32, _}, :os.type()) or is_nil(System.find_executable("python3"))

  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
  end

  for scenario <- [
        "gear_q",
        "ctrl_c",
        "crash",
        "startup_failure",
        "owner_exit"
      ] do
    @tag timeout: 30_000
    test "real terminal restores logging and emits mode resets after #{scenario}", %{
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

      # Track final reporting modes rather than interpreting leftover input as
      # evidence of an enabled mode. Cleanup can run more than once on failure.
      [before_console | _] = String.split(output, "TUI_CONSOLE_RESTORED", parts: 2)
      modes = Regex.scan(~r/\e\[\?([0-9;]+)([hl])/, before_console)

      final =
        Enum.reduce(modes, %{}, fn [_, numbers, setting], acc ->
          Enum.reduce(String.split(numbers, ";"), acc, &Map.put(&2, &1, setting))
        end)

      for mode <- ~w(1000 1002 1003 1006 1015 1004 2004 1049) do
        assert final[mode] == "l", "mode #{mode} remained enabled: #{inspect(final)}"
      end

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
