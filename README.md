# Alto

Alto is a small, composable execution runtime written in Elixir. It handles
bounded model and tool execution, approvals, cancellation, owned children,
typed content, and saved-session recovery. Hosts choose the agent's policy
and implementations.

The repository contains three independently built packages:

| Package | Owns | Depends on |
| --- | --- | --- |
| `alto` (repository root) | Execution contracts, shared correctness mechanisms, persistence and recovery | Elixir/OTP and `nimble_options` |
| [`alto_contrib`](packages/alto_contrib/README.md) | Providers, coding tools, Git workspaces, external clients, CLI/server hosts, prompts and application defaults | `alto` |
| [`alto_tui`](packages/alto_tui/README.md) | Terminal interface, task catalog, workspace navigation and UI state | `alto` and `alto_contrib` |

Dependencies point toward core. Installing `alto` does not install HTTP adapters,
server transports or terminal libraries.

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

Alto contrib supplies streaming OpenAI-compatible and Anthropic providers, file
and command tools, context reducers, agent tools, and Git workspace implementations.
The optional TUI also supports a Codex backend. Each can be selected and composed
through configuration.

## Get started

The supported baseline is Linux with Elixir 1.18 and OTP 27. Durable storage uses
the host `flock` utility; sandboxed command execution uses Bubblewrap (`bwrap`).

```sh
git clone https://github.com/STACKSKB/alto.git
cd alto/packages/alto_contrib
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
files. See the [example agent configurations](examples/README.md#agent-configurations)
for minimal coding, read-only review, sandboxed workspaces, bounded teams and a
document assistant. Select the larger coding profile to add file edits, sandboxed commands,
Git tools, and agents:

```sh
mix alto --config ../../alto.agentic.exs "Run the tests and fix the failure"
```

Attach local files with repeated `--attach FILE` arguments, including when
resuming a session. Supported inputs depend on the selected model; see
[attachments and model inputs](docs/configuration.md#attachments-and-model-inputs).

For the terminal UI:

```sh
cd ../alto_tui
mix deps.get
mix alto.tui --config ../../alto.agentic.exs
```

The TUI provides streaming Markdown, provider and model pickers, approvals,
workspace and task navigation, conversation search, and subagent inspection.
See the [TUI guide](packages/alto_tui/README.md) for controls and configuration.

Build a standalone CLI from `packages/alto_contrib` with `mix escript.build`, then
run `./alto --help`.

## Make it yours

Start with the shipped defaults and override ordinary Elixir values:

```elixir
# alto.exs
Alto.default_config()
|> Keyword.merge(
  tools: [Alto.Contrib.Tools.ListFiles, Alto.Contrib.Tools.ReadFile, Alto.Contrib.Tools.SearchFiles],
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

A host using the supplied implementations can depend on
`{:alto_contrib, path: "../alto/packages/alto_contrib"}` from a local checkout.
This dependency includes the matching core checkout. Compose application defaults explicitly:

```elixir
{:ok, options} = Alto.Contrib.Config.load("profiles/review/alto.exs")
%Alto.Runner.Result{status: :ok, output: answer} = Alto.Contrib.run("Review the parser", options)
```

`Alto.Contrib.start/2` and `Alto.Contrib.resume/3` apply the same application defaults.
`Alto.await/2` and `Alto.cancel/2` operate on their runtime handles. Hosts supplying
all policies themselves can use `Alto.run/2`, `Alto.start/2`, and `Alto.resume/3`. Use `Alto.rule_loop/1` for providerless workflows,
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
