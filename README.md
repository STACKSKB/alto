# Alto

Alto is a lightweight, customizable agent harness written in Elixir. Use it as a
terminal coding assistant, run a task from the command line, or compose it into
an application. It handles the model/tool loop, streaming, approvals,
cancellation, and saved sessions while you choose how the agent works.

The goal is an **xmonad-like agent harness**: configure it in real code, compose
small parts, and replace the parts that do not fit your workflow. An `alto.exs`
is an Elixir program returning your configuration. You can keep several of
them for different models, projects, or sessions.

## Goals

- **Lightweight.** Keep the core focused and resource use bounded. The terminal
  UI, external tools, and application integrations are optional components.
- **Customizable.** Choose the provider, model, prompt, tools, approval policy,
  command executor, context policy, and execution limits in Elixir.
- **Composable.** Reuse the supplied components or implement their contracts.
  Build a coding agent, a tool-free chat session, a deterministic workflow, or
  your own execution host from the same pieces.
- **Flexible across models and sessions.** Use a separate `alto.exs` for each
  workflow, share a base configuration, or expose several named configurations
  from a resident service. Configuration is an ordinary value passed to a run.
- **Explicit about execution.** Tools have defined authority, mutations can
  require approval, and runs can be cancelled. Saved sessions retain history;
  interrupted effects retain their uncertainty.

Alto includes streaming OpenAI-compatible and Anthropic providers, file and
command tools, context reduction, subagents and messaging, and Git workspaces.
The optional TUI also supports a Codex backend. Each can be selected and composed
through configuration.

## Get started

The supported baseline is Linux with Elixir 1.18 and OTP 27. Durable storage uses
the host `flock` utility; sandboxed command execution uses Bubblewrap (`bwrap`).

```sh
git clone https://github.com/STACKSKB/alto.git
cd alto
mix deps.get
mix alto --setup
mix alto "Explain this repository"
```

The default CLI uses OpenRouter. `--setup` saves a key and default model in the
private per-user credential store. For environment-based setup:

```sh
export OPENROUTER_API_KEY="..."
export ALTO_MODEL="provider/model"
mix alto "Explain this repository"
```

`ALTO_API_KEY` is also accepted. The default CLI tools list, read, and search
files. Select the supplied coding profile to add file edits, sandboxed commands,
Git tools, and agents:

```sh
mix alto --config alto.agentic.exs "Run the tests and fix the failure"
```

For the terminal UI:

```sh
cd packages/alto_tui
mix deps.get
mix alto.tui --config ../../alto.agentic.exs
```

The TUI provides streaming Markdown, provider and model pickers, approvals,
workspace and task navigation, conversation search, and subagent inspection.
See the [TUI guide](packages/alto_tui/README.md) for controls and configuration.

Build a standalone CLI with `mix escript.build`, then run `./alto --help`.

## Make it yours

Start with the shipped defaults and override ordinary Elixir values:

```elixir
# alto.exs
Alto.default_config()
|> Keyword.merge(
  tools: [Alto.Tools.ListFiles, Alto.Tools.ReadFile, Alto.Tools.SearchFiles],
  max_steps: 48,
  run_timeout: 30 * 60 * 1_000
)
```

Without a `provider` entry, the CLI resolves your OpenRouter credentials and
model. `Alto.default_config()` itself supplies no provider or credentials.

Choose a config explicitly for each task or session:

```sh
mix alto --config profiles/review/alto.exs "Review this change"
mix alto --config profiles/local/alto.exs "Explain the parser"
mix alto --resume SESSION_ID --config profiles/review/alto.exs "Check the tests too"
```

Configuration files can import shared code, read environment variables, and
construct custom components. Alto evaluates them as trusted Elixir. Workspace
configs are selected explicitly; a repository's `alto.exs` is never discovered
and executed automatically. The [configuration guide](docs/configuration.md)
covers multiple profiles, provider setup, sessions, and defaults.

## Use Alto in an application

Add Alto from source to your application's dependencies:

```elixir
{:alto, git: "https://github.com/STACKSKB/alto.git"}
```

The same configuration works through the library API:

```elixir
{:ok, options} = Alto.Config.load("profiles/review/alto.exs")
%Alto.Runner.Result{status: :ok, output: answer} = Alto.run("Review the parser", options)
```

`Alto.start/2`, `Alto.await/2`, and `Alto.cancel/2` support asynchronous runs.
Use `Alto.resume/3` for follow-ups, `Alto.rule_loop/1` for providerless workflows,
or `Alto.loop/2` to supply your own control policy. A resident service can expose
runs and saved sessions to clients over Unix sockets or WebSockets.

## Documentation

- [Guides and API contracts](docs/README.md)
- [Configuration and multiple `alto.exs` profiles](docs/configuration.md)
- [Terminal UI](packages/alto_tui/README.md)
- [Application examples](examples/README.md)
- [Front-end protocol](PROTOCOL.md)
- [Changelog](CHANGELOG.md)

Alto is distributed under the [MIT License](LICENSE).
