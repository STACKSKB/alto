defmodule Alto.TUI.Clipboard do
  @moduledoc "Desktop clipboard helpers with an OSC 52 fallback for remote terminals."

  @helpers %{
    write: [
      {"WAYLAND_DISPLAY", "wl-copy", []},
      {"DISPLAY", "xclip", ["-selection", "clipboard", "-in"]},
      {"DISPLAY", "xsel", ["--clipboard", "--input"]},
      {nil, "pbcopy", []}
    ],
    read: [
      {"WAYLAND_DISPLAY", "wl-paste", ["--no-newline"]},
      {"DISPLAY", "xclip", ["-selection", "clipboard", "-o"]},
      {"DISPLAY", "xsel", ["--clipboard", "--output"]},
      {nil, "pbpaste", []}
    ]
  }

  @doc "Encode text as an OSC 52 clipboard write; text cannot inject terminal commands."
  def sequence(text), do: "\e]52;c;" <> Base.encode64(text) <> "\a"

  @doc "Copy through a desktop helper, falling back to a terminal clipboard request."
  def write(text) do
    command = desktop_command(:write)

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

      # Redirect output too: X11 owners may fork to retain the selection.
      with {:ok, _} <-
             command(
               {"/bin/sh", ["-c", ~s(exec "$@" < "$0" > /dev/null 2>&1), path, program | args]}
             ),
           do: :ok
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
    case image_command() do
      nil ->
        command(desktop_command(:read))

      {program, args, media} ->
        case command({program, args}) do
          {:ok, bytes} -> {:ok, {:image, bytes, media}}
          _ -> command(desktop_command(:read))
        end
    end
  end

  defp image_command do
    cond do
      System.get_env("WAYLAND_DISPLAY") && System.find_executable("wl-paste") ->
        program = System.find_executable("wl-paste")

        case command({program, ["--list-types"]}) do
          {:ok, types} ->
            media = Enum.find(["image/png", "image/jpeg"], &(&1 in String.split(types, "\n")))
            if media, do: {program, ["--type", media], media}

          _ ->
            nil
        end

      System.get_env("DISPLAY") && System.find_executable("xclip") ->
        program = System.find_executable("xclip")

        case command({program, ["-selection", "clipboard", "-o", "-t", "TARGETS"]}) do
          {:ok, types} ->
            media = Enum.find(["image/png", "image/jpeg"], &(&1 in String.split(types)))
            if media, do: {program, ["-selection", "clipboard", "-o", "-t", media], media}

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  defp command(nil), do: {:error, :unavailable}

  defp command({program, args}) do
    invocation = %{
      executable: program,
      args: args,
      cwd: File.cwd!(),
      timeout_ms: 1_000,
      max_output_bytes: 6_000_000
    }

    case Alto.Command.Executors.Unsandboxed.execute(invocation) do
      {:ok, %{exit_status: 0, truncated: false} = result} ->
        if result[:encoding] == "base64",
          do: Base.decode64(result.output_base64),
          else: {:ok, result.output}

      _ ->
        {:error, :unavailable}
    end
  end

  defp desktop_command(direction) do
    Enum.find_value(Map.fetch!(@helpers, direction), fn {display, name, args} ->
      if is_nil(display) || System.get_env(display) do
        case System.find_executable(name) do
          nil -> nil
          path -> {path, args}
        end
      end
    end)
  end
end
