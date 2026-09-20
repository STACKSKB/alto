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

  def name(_opts), do: :echo
  def schema(_opts), do: %{parameters: %{type: "object", properties: %{}}}
  def execution_mode(_opts), do: :parallel
  def approval(_opts), do: :never
  def run(arguments, _context, _opts), do: {:ok, arguments}
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
runtime, a fresh temporary directory, and no network by default. With
`--sandbox-command`, existing `.git` metadata is mounted read-only. CLI native
file tools also protect `.git`; the coding profile
provides a separate approved Git-mutation capability. Hosts can configure these
policies independently (see [extension boundaries](docs/extensions.md)). Use
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
mix deps.get
mix alto.tui --config ../../alto.agentic.exs
```

In the workspace dialog (`Ctrl+G`, then `W`), type a new folder path and
click **Create folder** or press `Ctrl+N` to create it and open the workspace.
Missing parent folders are created too. `Enter` continues to open an existing
folder; creating a workspace preserves the current draft.

Assistant responses render as Markdown while streaming and when reopening a task:
headings and emphasis are styled, fenced code retains indentation with syntax
color, and tables use aligned columns when they fit or labeled records for long
reports. Selection copies the visible formatted text; saved messages retain the
original Markdown. Layout caches and viewport-only painting keep report formatting
out of the pointer-motion path. The shared renderer is also used by Zekkyou.

The TUI example hosts runs locally and uses the same approval, execution,
cancellation, and session contracts as other hosts. Applications can build
independently reconnectable clients using the transport contract below.

## Local front-end protocol

`Alto.Protocol` defines versioned JSON envelopes for Unix socket NDJSON and
WebSocket clients. The server streams bounded durable and live events, accepts
trusted configuration names, exposes approval responses, and supports bounded
session and queue inspection. Clients cannot send Elixir code or inline loop,
provider, tool, or policy modules. See [PROTOCOL.md](./PROTOCOL.md) for the
wire contract. WebSocket upgrades require a generated token by default; open the
capability URL printed by `--serve`. Native clients send a Bearer token, and hosts
can replace the listener authentication policy.

## Examples

The [examples index](./examples/README.md) covers the maintained repository
maintenance and document intake applications, optional Oban host, and coding
configuration profile. Each example keeps authentication, persistence, retries, and
external side effects in the host application while Alto enforces its own
execution and resource boundaries.

The feature guides cover [explicit tool batches](docs/tool-batches.md),
[context reduction](docs/context-reduction.md), [interactive input](docs/interactive-input.md),
[conversation revisions](docs/conversations.md), [multimodal tool content](docs/multimodal-content.md),
[extension boundaries](docs/extensions.md), and the [offline benchmark and provider comparison](docs/benchmarks.md).

The checked-in [`alto.agentic.exs`](./alto.agentic.exs) profile is an explicit
coding configuration, not a library default. It uses up to four concurrent
approval-free read calls, permits eight context reductions, and starts context
reduction at 85% of the available input window. Settled session history keeps
complete conversation boundaries for recovery. Set `ALTO_VISION=1` only when
the selected model supports vision; this enables the bounded image reader and
passes images to the provider adapter. Library defaults remain conservative,
with serial tools, no automatic image capability, and compaction disabled unless
the host opts in. When enabled, compaction permits one reduction by default.
Team composition is explicit: trusted loops request children, each child
inherits an exact subset of the parent's tools and authority, and
`Alto.Subagents.bounded/1` sets depth, child-count, and concurrency ceilings.
Use a shared budget account when the team also needs bounded effect and model
request counts; delegation never widens capabilities or the root budget.

Alto is distributed under the [MIT License](./LICENSE).

Durable hosts can use [approval continuations](docs/checkpoints.md) to persist
exact prepared operations, release workers while awaiting decisions, and resume
under preserved budgets with the existing queue and operation ledger.

Trusted loops can request [bounded subagent batches](docs/subagents.md), sharing
execution budgets and inherited tool authority while running children concurrently.
Hosts can opt into durable isolated Git workspaces and immutable patch capture.
`Alto.Workspaces.prepare_apply/3` captures a portable approval manifest, and
`apply/2` checks the saved resource revision, patch hash, repository and affected
files before integrating into the source working tree. The index stays unchanged.
Disjoint patches can be reviewed together and applied independently; overlapping
edits invalidate the saved approval. Applied patches remain available for review
until explicitly discarded. Named agent profiles, approval and integration
selection, and communication policy remain host concerns.

Host extension boundaries, input transforms, and provider-aware context
estimates are described in [docs/extensions.md](docs/extensions.md).

Preparation is read-only. Application serializes callers sharing the same workspace
manager; it does not exclude unrelated editors or Git processes. Errors before
dispatch are known refusals. Failures after Git starts, including incomplete durable
recording, return `{:unknown, reason}` and retain the resource for review without
automatic replay. An interrupted application is not an atomic multi-file rollback.
The Git integration manifest is bounded to 256 affected regular files, 128 MiB of
existing affected content and 32 KB of serialized metadata; captured patches are
bounded to 1 MB. Symlink paths and repository filters remain unsupported.

### Replaceable execution hosts

The default `Alto.Runner.Serial` composes shared execution components. Select a host with `runner:` in `Alto.Config` or
run options. Handles are opaque and results use `Alto.Runner.Result`; registry
and TUI integrations consume completion notifications instead of inspecting
Tasks. Serial can optionally wait for a one-use admission ticket before each effect.
See [execution hosts](docs/runners.md) for contracts and examples.
