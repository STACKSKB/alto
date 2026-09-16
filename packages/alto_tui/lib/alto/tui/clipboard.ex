defmodule Alto.TUI.Clipboard do
  @moduledoc "Terminal clipboard output, including SSH terminals supporting OSC 52."

  @doc "Encode text as an OSC 52 clipboard write; text cannot inject terminal commands."
  def sequence(text), do: "\e]52;c;" <> Base.encode64(text) <> "\a"

  @doc "Ask the attached terminal to copy text to its system clipboard."
  def write(text) do
    sequence = sequence(text)

    sequence =
      if System.get_env("TMUX"),
        do: "\ePtmux;" <> String.replace(sequence, "\e", "\e\e") <> "\e\\",
        else: sequence

    IO.binwrite(:stdio, sequence)
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
