defmodule Alto.TUI.Logging do
  @moduledoc false

  @handler __MODULE__

  def default_path do
    Path.join([Alto.Storage.state_home(), "alto", "logs", "tui.log"])
  end

  # Logger writes outside ratatui's frame buffer. Even one console warning can
  # scroll the screen and leave subsequent differential draws permanently stale.
  def with_file(opts, fun) do
    path = Keyword.get(opts, :log_path, default_path()) |> Path.expand()

    with :ok <- Alto.Storage.ensure_private_dir(Path.dirname(path)),
         :ok <- prepare_file(path),
         :ok <- add_file_handler(path) do
      consoles = Enum.filter(:logger.get_handler_config(), &console?/1)

      try do
        Enum.each(consoles, fn %{id: id} ->
          :ok = :logger.set_handler_config(id, :level, :none)
        end)

        # Drain console writes already queued before giving the TUI the screen.
        Logger.flush()
        fun.()
      after
        Logger.flush()
        :logger.remove_handler(@handler)

        Enum.each(consoles, fn %{id: id, level: level} ->
          :logger.set_handler_config(id, :level, level)
        end)
      end
    else
      {:error, reason} -> {:error, {:tui_log_setup_failed, path, reason}}
    end
  end

  defp console?(%{module: :logger_std_h, config: %{type: type}}),
    do: type in [:standard_io, :standard_error]

  defp console?(_), do: false

  defp prepare_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> Alto.Storage.ensure_private_file(path)
      {:error, :enoent} -> Alto.Storage.ensure_private_file(path)
      {:ok, _} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_file_handler(path) do
    :logger.add_handler(@handler, :logger_std_h, %{
      level: :all,
      formatter: Logger.default_formatter(colors: [enabled: false]),
      config: %{
        type: :file,
        file: String.to_charlist(path),
        max_no_bytes: 5_000_000,
        max_no_files: 3
      }
    })
  end
end
