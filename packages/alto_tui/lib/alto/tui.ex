defmodule Alto.TUI do
  @moduledoc "Entry point for Alto's local terminal coding harness."

  @doc "Run the TUI until the user exits."
  @spec run(Alto.Config.t() | Path.t(), keyword()) :: :ok | {:error, term()}
  def run(config_or_path, opts \\ []) do
    with {:ok, _apps} <- Application.ensure_all_started(:alto),
         {:ok, config} <- resolve_config(config_or_path),
         :ok <- prepare_catalog(config, opts) do
      run_app(config, opts)
    end
  end

  @doc false
  def prepare_catalog(%Alto.Config{} = config, opts \\ []) do
    catalog_opts = Alto.TUI.State.catalog_options(config, opts)

    case Alto.Harness.Catalog.read(catalog_opts) do
      {:ok, _catalog} ->
        :ok

      {:error, reason} ->
        if Alto.Harness.Catalog.invalid_data?(reason) do
          path =
            Keyword.get(catalog_opts, :path, Alto.Harness.Catalog.default_path(catalog_opts))
            |> Path.expand()

          if confirm_catalog_overwrite(path, reason, opts),
            do: Alto.Harness.Catalog.replace_invalid(catalog_opts),
            else: {:error, {:catalog_overwrite_declined, path}}
        else
          {:error, reason}
        end
    end
  end

  defp confirm_catalog_overwrite(path, reason, opts) do
    input = Keyword.get(opts, :input, :stdio)
    output = Keyword.get(opts, :output, :stderr)

    detail =
      case reason do
        {:catalog_invalid, _} -> "unsupported version or structure"
        {:catalog_invalid_json, _, _} -> "invalid JSON"
        {:catalog_too_large, _, _} -> "file exceeds the catalog size limit"
      end

    IO.write(output, "Warning: catalog #{path} is invalid (#{detail}).\n")

    IO.write(
      output,
      "Overwrite it with an empty catalog? This removes its saved projects and tasks. [y/N] "
    )

    case IO.gets(input, "") do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      _other -> false
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
