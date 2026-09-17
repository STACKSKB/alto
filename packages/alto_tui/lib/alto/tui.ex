defmodule Alto.TUI do
  @moduledoc "Entry point for Alto's local terminal coding harness."

  @doc "Run the TUI until the user exits."
  @spec run(Alto.Config.t() | Path.t(), keyword()) :: :ok | {:error, term()}
  def run(config_or_path, opts \\ []) do
    with {:ok, _apps} <- Application.ensure_all_started(:alto),
         {:ok, config} <- resolve_config(config_or_path) do
      run_app(config, opts)
    end
  end

  defp run_app(config, opts) do
    owner = self()

    # Isolate start_link's exit signals without changing the caller's exit
    # handling. This owner keeps logging protected through startup and shutdown.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        owner_ref = Process.monitor(owner)

        result =
          Alto.TUI.Logging.with_file(opts, fn -> start_app(config, opts, owner_ref) end)

        exit({:tui_result, result})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:tui_result, result}} -> result
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, {:tui_stopped, reason}}
    end
  end

  defp start_app(config, opts, owner_ref) do
    with {:ok, pid} <-
           Alto.TUI.App.start_link(
             opts
             |> Keyword.put(:config, config)
             |> Keyword.put_new(:name, nil)
             |> Keyword.put_new(:mouse_capture, true)
             |> Keyword.put_new(:poll_interval, 24)
           ) do
      receive do
        {:EXIT, ^pid, :normal} ->
          :ok

        {:EXIT, ^pid, reason} ->
          {:error, {:tui_stopped, reason}}

        {:DOWN, ^owner_ref, :process, _owner, _reason} ->
          GenServer.stop(pid, :normal, :infinity)
          {:error, :tui_owner_stopped}
      end
    end
  end

  defp resolve_config(%Alto.Config{} = config), do: {:ok, config}
  defp resolve_config(path) when is_binary(path), do: Alto.Config.load(path)
  defp resolve_config(other), do: {:error, {:invalid_tui_config, other}}
end
