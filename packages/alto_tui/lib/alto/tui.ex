defmodule Alto.TUI do
  @moduledoc "Entry point for Alto's local terminal coding harness."

  @doc "Run the TUI until the user exits."
  @spec run(Alto.Config.t() | Path.t(), keyword()) :: :ok | {:error, term()}
  def run(config_or_path, opts \\ []) do
    with {:ok, _apps} <- Application.ensure_all_started(:alto),
         {:ok, config} <- resolve_config(config_or_path),
         {:ok, pid} <-
           Alto.TUI.App.start_link(
             opts
             |> Keyword.put(:config, config)
             |> Keyword.put_new(:name, nil)
             |> Keyword.put_new(:mouse_capture, true)
             |> Keyword.put_new(:poll_interval, 24)
           ) do
      Process.unlink(pid)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
        {:DOWN, ^ref, :process, ^pid, reason} -> {:error, {:tui_stopped, reason}}
      end
    end
  end

  defp resolve_config(%Alto.Config{} = config), do: {:ok, config}
  defp resolve_config(path) when is_binary(path), do: Alto.Config.load(path)
  defp resolve_config(other), do: {:error, {:invalid_tui_config, other}}
end
