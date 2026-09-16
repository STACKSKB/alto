defmodule Alto.TUI.Clipboard do
  @moduledoc "Desktop clipboard helpers with an OSC 52 fallback for remote terminals."

  @doc "Encode text as an OSC 52 clipboard write; text cannot inject terminal commands."
  def sequence(text), do: "\e]52;c;" <> Base.encode64(text) <> "\a"

  @doc "Copy through a desktop helper, falling back to a terminal clipboard request."
  def write(text) do
    command =
      cond do
        System.get_env("WAYLAND_DISPLAY") && System.find_executable("wl-copy") ->
          {System.find_executable("wl-copy"), []}

        System.get_env("DISPLAY") && System.find_executable("xclip") ->
          {System.find_executable("xclip"), ["-selection", "clipboard", "-in"]}

        System.get_env("DISPLAY") && System.find_executable("xsel") ->
          {System.find_executable("xsel"), ["--clipboard", "--input"]}

        System.find_executable("pbcopy") ->
          {System.find_executable("pbcopy"), []}

        true ->
          nil
      end

    if command && desktop_write(command, text) == :ok, do: :ok, else: terminal_write(text)
  end

  @doc "Describe confirmed desktop copies separately from unacknowledged terminal requests."
  def notice(:ok), do: "Copied selection"
  def notice(:terminal_requested), do: "Copy sent to terminal; ^V local"
  def notice(_), do: "Clipboard unavailable; ^V local"

  defp desktop_write({program, args}, text) do
    # Helpers consume stdin, not shell-interpolated text or public command-line
    # arguments. The private directory also protects copied credentials.
    directory =
      Path.join(
        System.tmp_dir!(),
        "alto-clipboard-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    try do
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      path = Path.join(directory, "text")
      File.write!(path, text)
      File.chmod!(path, 0o600)

      task =
        Task.async(fn ->
          try do
            # Redirect output too: X11 owners may fork to retain the selection.
            case System.cmd("/bin/sh", [
                   "-c",
                   ~s(exec "$@" < "$0" > /dev/null 2>&1),
                   path,
                   program | args
                 ]) do
              {_, 0} -> :ok
              _ -> {:error, :unavailable}
            end
          rescue
            _ -> {:error, :unavailable}
          end
        end)

      case Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :unavailable}
      end
    rescue
      _ -> {:error, :unavailable}
    after
      File.rm_rf(directory)
    end
  end

  defp terminal_write(text) do
    sequence = sequence(text)

    sequence =
      if System.get_env("TMUX"),
        do: "\ePtmux;" <> String.replace(sequence, "\e", "\e\e") <> "\e\\",
        else: sequence

    case IO.binwrite(:stdio, sequence) do
      :ok -> :terminal_requested
      error -> error
    end
  end

  @doc "Read the local desktop clipboard when a supported helper is installed."
  def read do
    command =
      cond do
        System.get_env("WAYLAND_DISPLAY") && System.find_executable("wl-paste") ->
          {"wl-paste", ["--no-newline"]}

        System.get_env("DISPLAY") && System.find_executable("xclip") ->
          {"xclip", ["-selection", "clipboard", "-o"]}

        System.get_env("DISPLAY") && System.find_executable("xsel") ->
          {"xsel", ["--clipboard", "--output"]}

        System.find_executable("pbpaste") ->
          {"pbpaste", []}

        true ->
          nil
      end

    if command do
      task =
        Task.async(fn ->
          {program, args} = command

          try do
            case System.cmd(program, args, stderr_to_stdout: true) do
              {text, 0} -> {:ok, text}
              _ -> {:error, :unavailable}
            end
          rescue
            _ -> {:error, :unavailable}
          end
        end)

      case Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end
end
