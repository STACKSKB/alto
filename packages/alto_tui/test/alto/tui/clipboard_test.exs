defmodule Alto.TUI.ClipboardTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Alto.TUI.Clipboard

  setup do
    path =
      Path.join(System.tmp_dir!(), "alto-clipboard-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    vars = ["PATH", "DISPLAY", "WAYLAND_DISPLAY", "TMUX", "CLIPBOARD_TEST_OUTPUT"]
    previous = Map.new(vars, &{&1, System.get_env(&1)})
    System.put_env("PATH", path)
    System.put_env("DISPLAY", ":test")
    System.delete_env("WAYLAND_DISPLAY")
    System.delete_env("TMUX")
    System.put_env("CLIPBOARD_TEST_OUTPUT", Path.join(path, "output"))

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(path)
    end)

    %{path: path}
  end

  test "desktop copy supplies literal stdin, supports clipboard reads, and cleans private files",
       %{path: path} do
    executable(path, "xclip", """
    case "$*" in
      '-selection clipboard -in') /bin/cat > "$CLIPBOARD_TEST_OUTPUT" ;;
      '-selection clipboard -o') /bin/cat "$CLIPBOARD_TEST_OUTPUT" ;;
      *) exit 2 ;;
    esac
    """)

    text = "猫\n'$(false)' `false` \e]52;c;payload\a"
    before = Path.wildcard(Path.join(System.tmp_dir!(), "alto-clipboard-*"))
    assert capture_io(fn -> assert Clipboard.write(text) == :ok end) == ""
    assert File.read!(Path.join(path, "output")) == text
    assert Clipboard.read() == {:ok, text}
    assert Path.wildcard(Path.join(System.tmp_dir!(), "alto-clipboard-*")) == before
  end

  test "missing or failed desktop helpers request OSC 52 without claiming confirmation", %{
    path: path
  } do
    text = "hello\n猫\e]52;c;bad\a"
    request = capture_io(fn -> assert Clipboard.write(text) == :terminal_requested end)
    assert String.starts_with?(request, "\e]52;c;")
    assert String.ends_with?(request, "\a")
    refute request =~ "\e]52;c;bad"
    encoded = request |> String.trim_leading("\e]52;c;") |> String.trim_trailing("\a")
    assert Base.decode64!(encoded) == text

    executable(path, "xclip", "exit 1")

    assert capture_io(fn -> assert Clipboard.write("hello") == :terminal_requested end) ==
             Clipboard.sequence("hello")

    assert Clipboard.notice(:terminal_requested) =~ "sent to terminal"
  end

  test "tmux fallback escapes OSC payload" do
    System.put_env("TMUX", "/tmp/test")
    expected = "\ePtmux;" <> String.replace(Clipboard.sequence("hello"), "\e", "\e\e") <> "\e\\"
    assert capture_io(fn -> Clipboard.write("hello") end) == expected
  end

  defp executable(path, name, body) do
    file = Path.join(path, name)
    File.write!(file, "#!/bin/sh\n" <> body)
    File.chmod!(file, 0o700)
  end
end
