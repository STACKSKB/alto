defmodule Alto.CLI.Arguments do
  @moduledoc false

  @switches [
    config: :string,
    no_config: :boolean,
    setup: :boolean,
    serve: :boolean,
    socket: :string,
    port: :integer,
    base_url: :string,
    model: :string,
    api_key_env: :string,
    allow_write: :boolean,
    allow_command: :boolean,
    sandbox_command: :boolean,
    allow_command_network: :boolean,
    approve_all: :boolean,
    no_tools: :boolean,
    max_steps: :integer,
    resume: :string,
    sessions: :boolean,
    no_session: :boolean,
    timeout: :integer,
    system_prompt: :string,
    no_system_prompt: :boolean,
    no_project_instructions: :boolean,
    help: :boolean
  ]

  @aliases [h: :help, m: :model]

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

    Model:
      -m, --model MODEL          model identifier (or ALTO_MODEL); otherwise use
                                the saved selection or open first-run setup

    Provider:
      --base-url URL            API root (default: ALTO_BASE_URL, then OpenRouter)
      --api-key-env NAME        read the bearer token from this environment variable
      --timeout MILLISECONDS    per-request timeout (default: 120000)

    Loop:
      --max-steps COUNT         maximum model calls (default: 32)
      --no-tools                expose no workspace tools
      --allow-write             opt in to bounded edit_file and write_file tools
      --allow-command           opt in to bounded, unsandboxed argv execution
      --sandbox-command         use Bubblewrap; workspace writable, host hidden
      --allow-command-network   let Bubblewrap commands inherit host networking
      --approve-all             run mutating and command tools without prompting
      --system-prompt TEXT      replace the small default system prompt
      --no-system-prompt        send no system prompt
      --no-project-instructions ignore alto.md / AGENTS.md in the workspace

    Sessions:
      --resume ID               continue a persisted session with a follow-up task
      --sessions                list persisted sessions, then exit
      --no-session              do not persist this run (sessions default on)

    Mutating and command tools require per-invocation approval unless
    --approve-all is set. OpenRouter keys resolve from ALTO_API_KEY,
    OPENROUTER_API_KEY, or the private first-run credential store. Custom
    OpenAI-compatible endpoints use ALTO_API_KEY and then OPENAI_API_KEY.
    Configuration defaults to ALTO_CONFIG, then ~/.config/alto/config.exs (or
    $XDG_CONFIG_HOME/alto/config.exs). Configuration is trusted arbitrary Elixir.
    With --serve, the loaded configuration is served to front ends as "default";
    served runs answer approvals through the WebSocket instead of the terminal, and a
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
