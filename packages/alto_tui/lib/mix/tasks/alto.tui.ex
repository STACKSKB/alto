defmodule Mix.Tasks.Alto.Tui do
  @shortdoc "Start Alto's mouse-aware coding TUI"

  use Mix.Task

  @switches [
    config: :string,
    project: :string,
    catalog: :string,
    credentials: :string,
    help: :boolean
  ]
  @aliases [c: :config, p: :project, h: :help]

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, [], []} -> run_options(opts)
      {_opts, args, []} -> Mix.raise("unexpected arguments: #{Enum.join(args, " ")}")
      {_opts, _args, invalid} -> Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  defp run_options(opts) do
    if Keyword.get(opts, :help, false) do
      Mix.shell().info(usage())
    else
      config = Keyword.get(opts, :config, "alto.agentic.exs")

      tui_opts =
        []
        |> put_if(:project, Keyword.get(opts, :project))
        |> put_if(:path, Keyword.get(opts, :catalog))
        |> put_if(:credentials_path, Keyword.get(opts, :credentials))

      case Alto.TUI.run(config, tui_opts) do
        :ok -> :ok
        {:error, reason} -> Mix.raise("Alto TUI failed: #{inspect(reason)}")
      end
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    """
    mix alto.tui [options]

      --config, -c PATH   trusted Alto config (default: alto.agentic.exs)
      --project, -p PATH  workspace to open (default: current directory)
      --catalog PATH      harness catalog override
      --credentials PATH  provider credential store override

    Ctrl+G is the gear leader. Follow it with B/A/P/M/E/W/T/N/D/Q.
    F2/F3/F4/F5 open approval/provider/model/backend directly; F6 toggles
    prose/code entry. Prose wraps by default. ^G D or the clickable D:CTX
    control opens narrow context as a drawer. Enter sends; Shift+Enter inserts
    a newline. Mouse clicks select and vertical seams can be dragged.
    """
  end
end
