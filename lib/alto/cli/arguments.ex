defmodule Alto.CLI.Arguments do
  @moduledoc false

  @switches [
    config: :string,
    no_config: :boolean,
    setup: :boolean,
    serve: :boolean,
    socket: :string,
    port: :integer,
    resume: :string,
    sessions: :boolean,
    no_session: :boolean,
    help: :boolean
  ]

  @aliases [h: :help]

  def parse(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {options, task, []} -> {:ok, options, task}
      {_options, _task, invalid} -> {:error, "invalid options: #{inspect(invalid)}"}
    end
  end

  def maybe_help(options) do
    if Keyword.get(options, :help, false) do
      IO.puts(usage())
      :help
    else
      :continue
    end
  end

  defp usage do
    """
    Usage: alto [options] TASK...
           printf 'TASK' | alto [options]
           alto --serve [options]

    Configuration:
      --config FILE             load trusted compiled Elixir configuration
      --no-config               ignore ALTO_CONFIG and the per-user config
      --setup                   configure OpenRouter key and default model, then exit
      --serve                   run as a resident server (Unix socket + WebSocket)
      --socket PATH             socket path (default: $ALTO_STATE_HOME/alto/alto.sock,
                                else $XDG_STATE_HOME/alto/alto.sock or ~/.local/state/alto/alto.sock)
      --port PORT               WebSocket port on 127.0.0.1 (default: 4747)

    Execution settings come from the trusted configuration: provider/model,
    credentials, tools and executors, approval, limits, prompt, and project instructions.
    Without a provider entry, Alto uses OpenRouter onboarding and ALTO_MODEL.
    Set provider: nil for a providerless loop. Default tools only read the workspace.

    Sessions:
      --resume ID               continue a persisted session with a follow-up task
      --sessions                list persisted sessions, then exit
      --no-session              do not persist this run (sessions default on)

    OpenRouter keys resolve from ALTO_API_KEY, OPENROUTER_API_KEY, or the private
    first-run credential store. Configure other endpoints and credentials in Elixir.
    Configuration defaults to ALTO_CONFIG, then ~/.config/alto/config.exs (or
    $XDG_CONFIG_HOME/alto/config.exs). Configuration is trusted arbitrary Elixir.
    With --serve, the loaded configuration is served to front ends as "default";
    approval defaults to the WebSocket for served runs and the terminal for one-shot
    runs. Configured approval policies are honored in both modes, and a
    `listeners:` entry in the configuration selects the transports.
    One-shot runs persist under the state home ($ALTO_STATE_HOME, then
    $XDG_STATE_HOME, else ~/.local/state) and print their session id; continue one with
    --resume ID plus a follow-up task. Served runs persist only when the
    configuration opts in with sessions: true (or sessions with a
    session_dir); served clients discover sessions with the sessions
    command and resume with start_run plus resume:.
    """
  end
end
