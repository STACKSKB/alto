# Alto v0.0.1

Alto is a composable BEAM-native harness for bounded coding-agent workflows.
It provides a serial model/tool runner, durable sessions and event logs,
explicit approvals, workspace tools, provider adapters, and a small protocol
for local front ends. Applications choose the loop, tools, provider, approval
policy, executor, and resource limits as ordinary Elixir configuration.

## Install and run

This release targets Linux with Elixir 1.18 and OTP 27. Durable storage
requires the host `flock` utility; sandboxed commands additionally require
Bubblewrap. From a checkout:

```sh
mix deps.get
mix alto --help
```

The default CLI uses an OpenAI-compatible provider. Set a key and model, then
run a task:

```sh
export ALTO_API_KEY="..."
export ALTO_MODEL="provider/model"
mix alto "Explain this repository"
```

For OpenRouter, use `OPENROUTER_API_KEY` and optionally
`ALTO_BASE_URL=https://openrouter.ai/api/v1`. `--model` overrides
`ALTO_MODEL` and saved preferences. `mix alto --setup` stores the OpenRouter
key and model in the per-user credentials file with mode `0600`; credentials
are never written to the workspace or session startup metadata.

Build a standalone CLI with:

```sh
mix escript.build
./alto --model provider/model "Inspect this project"
```

The public source is [github.com/STACKSKB/alto](https://github.com/STACKSKB/alto).
Once the tagged release is available, a library application can depend on it
with:

```elixir
defp deps do
  [{:alto, git: "https://github.com/STACKSKB/alto.git", tag: "v0.0.1"}]
end
```

## A providerless library run

The rule loop is useful for deterministic workflows and tests. It executes
trusted, configured tool steps without making a model request:

```elixir
defmodule EchoTool do
  @behaviour Alto.Tool

  def name, do: :echo
  def schema, do: %{parameters: %{type: "object", properties: %{}}}
  def execution_mode, do: :parallel
  def approval, do: :never
  def run(arguments, _context), do: {:ok, arguments}
end

{:ok, result} =
  Alto.run(%{"message" => "hello"},
    loop: Alto.rule_loop(steps: ["echo"]),
    tools: [EchoTool],
    provider: nil
  )

result.output
# [%{"message" => "hello"}]
```

For model-driven work, pass a provider module or a compiled `Alto.Config`.
Provider, tool, loop, middleware, command-executor, search-backend, and inbox
behaviours are the extension contracts. `Alto.Capabilities` can describe the
effective configured tools, providers, and limits without exposing secrets.

## Workspace permissions and limits

Listing, reading, and bounded literal search are available by default. File
edits and whole-file writes require `--allow-write`. Command execution is
disabled unless explicitly enabled:

```sh
mix alto --allow-write --sandbox-command "Run the focused tests"
```

The Bubblewrap executor gives the command a writable workspace, a read-only
runtime, a fresh temporary directory, and no network by default. Use
`--allow-command` only for an explicitly unsandboxed executor. Alto prompts for
mutating and command tools unless `--approve-all` is selected.

The runner bounds model calls (`max_steps`), tool results, transcript and event
bytes, provider and tool time, approvals, queue records, operation history,
and ingress bodies. Queue and operation logs reject appends that exceed their
configured `max_log_bytes` limit. Session, credential, catalog, queue, and
ledger state uses private files and bounded reads. Cross-process storage uses
host advisory locks with bounded acquisition waits; uncertain external effects
remain unknown until reconciled.

## Optional terminal UI

The core production build does not require the native ExRatatui dependency.
The optional package in [`packages/alto_tui`](./packages/alto_tui) contains the
working terminal client and its shared sources. From this checkout:

```sh
cd packages/alto_tui
ALTO_TUI_LOCAL=1 mix deps.get
ALTO_TUI_LOCAL=1 mix alto.tui --config ../../alto.agentic.exs
```

The TUI example hosts runs locally and uses the same approval, execution,
cancellation, and session contracts as other hosts. Applications can build
independently reconnectable clients using the transport contract below.

## Local front-end protocol

`Alto.Protocol` defines versioned JSON envelopes for Unix socket NDJSON and
WebSocket clients. The server streams bounded durable and live events, accepts
trusted configuration names, exposes approval responses, and supports bounded
session and queue inspection. Clients cannot send Elixir code or inline loop,
provider, tool, or policy modules. See [PROTOCOL.md](./PROTOCOL.md) for the
wire contract.

## Examples

The [examples index](./examples/README.md) covers the maintained repository
maintenance and document intake applications, optional Oban host, and coding
configuration profile. Each example keeps authentication, persistence, retries, and
external side effects in the host application while Alto enforces its own
execution and resource boundaries.

Alto is distributed under the [MIT License](./LICENSE).
