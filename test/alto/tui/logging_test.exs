defmodule Alto.TUI.LoggingTest do
  use ExUnit.Case, async: false

  require Logger
  alias Alto.TUI.Logging

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
  end

  test "redirects stdout and stderr logs and preserves existing file handlers", %{tmp_dir: dir} do
    existing_path = Path.join(dir, "existing.log")
    path = Path.join(dir, "tui.log")

    :ok =
      :logger.add_handler(:tui_test_stderr, :logger_std_h, %{
        level: :warning,
        config: %{type: :standard_error}
      })

    :ok =
      :logger.add_handler(:tui_test_file, :logger_std_h, %{
        config: %{type: :file, file: String.to_charlist(existing_path)}
      })

    on_exit(fn ->
      :logger.remove_handler(:tui_test_stderr)
      :logger.remove_handler(:tui_test_file)
    end)

    before = handlers()

    assert :result ==
             Logging.with_file([log_path: path], fn ->
               assert {:ok, %{level: :none}} = :logger.get_handler_config(:default)
               assert {:ok, %{level: :none}} = :logger.get_handler_config(:tui_test_stderr)
               assert :logger.get_handler_config(:tui_test_file) == {:ok, before[:tui_test_file]}
               Task.async(fn -> Logger.warning("background warning retained") end) |> Task.await()
               Logger.debug("debug retained")
               :result
             end)

    assert handlers() == before
    assert File.read!(path) =~ "background warning retained"
    assert File.read!(path) =~ "debug retained"
    assert File.read!(existing_path) =~ "background warning retained"
    refute File.read!(path) =~ "\e["
  end

  test "restores console configuration when the protected operation raises", %{tmp_dir: dir} do
    before = handlers()

    assert_raise RuntimeError, "probe", fn ->
      Logging.with_file([log_path: Path.join(dir, "tui.log")], fn -> raise "probe" end)
    end

    assert handlers() == before
  end

  test "fails before entering the terminal if the log cannot be opened", %{tmp_dir: dir} do
    before = handlers()

    assert {:error, {:tui_log_setup_failed, ^dir, _}} =
             Logging.with_file([log_path: dir], fn -> flunk("must not start TUI") end)

    assert handlers() == before
  end

  defp handlers, do: Map.new(:logger.get_handler_config(), &{&1.id, &1})
end
