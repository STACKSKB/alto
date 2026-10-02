# Alto contrib

Optional implementations and application policy built on the Alto runtime.
This is a separate Mix application: it depends on `alto`; core never depends
on it. The terminal interface lives in `alto_tui`.

## Use it

From this directory:

```sh
mix deps.get
mix alto --setup
mix alto --config ../../alto.agentic.exs "Explain this repository"
mix escript.build
./alto --help
```

For a host application using a local checkout, add:

```elixir
{:alto_contrib, path: "../alto/packages/alto_contrib"}
```

The local package uses the sibling core checkout. Published source packages
fall back to the matching `alto` release. Configuration is ordinary trusted Elixir:

```elixir
{:ok, options} = Alto.Contrib.Config.load("alto.exs")
result = Alto.Contrib.run("Review the parser", options)
# Equivalent explicit composition:
result = Alto.run("Review the parser", Alto.Contrib.configure(options))
```

`start/2` and `resume/3` compose the same defaults. Runtime handles, results,
`await/2`, and `cancel/2` remain core APIs. CLI, resident server and native TUI
hosts perform this composition before entering the runtime.

## Ownership

| Area | Implementation |
| --- | --- |
| Provider HTTP/SSE codecs and image generation | `Alto.Contrib.Providers.*` |
| Provider metadata, credentials and model selection | `ProviderProfile`, `ProviderStore`, `Credentials`, `Reasoning`, `Usage` |
| File, command, Git, delegation and publication tools | `Alto.Contrib.Tools.*` |
| Execution environment and external subprocess policy | `Command.*`, `External.*`, `Codex.*` |
| Retained workspace implementations | `Workspaces.*`, implementing core `Alto.Resource` |
| Instruction discovery, prompts, context reducers and retry policy | `Project`, `Prompts.*`, `Context.Reducers.*`, `Retry.Transient` |
| File staging and presentation | `Attachment`, `Display`, `ToolDisplay` |
| CLI, socket/webhook/web server hosts and their wire protocol | `CLI`, `Listeners.*`, `Ingress.*`, `FrontEnd.*`, `Protocol` |

`configure/1` supplies transient retries, summary reduction when compaction is
enabled, project-file discovery when requested, and provider/model resolvers.
Explicit callbacks override these defaults. It does not fetch model catalogs
or start execution. Core accepts explicit project instructions or a loader;
compaction in core requires a strategy and retries require a policy.

## Migrating an existing configuration

Optional `Alto.Providers.*`, `Alto.Tools.*`, `Alto.Command.*`, `Alto.External.*`,
`Alto.Codex.*`, `Alto.Workspaces.*` and related implementation modules now live
under `Alto.Contrib.*`. `Alto.Harness.ProviderProfile` and `ProviderStore` become
`Alto.Contrib.ProviderProfile` and `ProviderStore`. Config file loading moves to
`Alto.Contrib.Config`; core `Alto.Config.default/1` remains available. Interactive,
delegated and socket approval functions move to `Alto.Contrib.Approval`; the
approval contract and classifier stay in core.

TUI catalog, folders and worktree actions become `Alto.TUI.Catalog`, `Folders`
and `Worktrees`. Run CLI/Mix application commands from this package; run TUI
commands from `../alto_tui`. The root project provides the runtime library.

Custom providers return canonical usage fields. Use `Alto.Contrib.Usage.normalize/1`
for common wire aliases and `from_codex/1` for Codex snapshots; core usage math
accepts canonical accounting. Provider extension fields remain bounded by the
transcript and cannot replace its structural fields.

Persistence formats and saved files are not rewritten by this migration.
Continuation fingerprints include code identity, so old checkpoints may be
rejected. Retain the original revision for outstanding continuations and
reconcile uncertain effects before creating new work; do not replay them to
work around a rejected checkpoint.

## Retaining command output

`RunCommand` and `RunShell` can preserve output omitted from their bounded inline
result. Enable retention in the host's executor options:

```elixir
{Alto.Contrib.Tools.RunCommand,
 executor:
   {Alto.Contrib.Command.Executors.Unsandboxed,
    output_retention: [directory: ".alto/command-output", max_bytes: 8_000_000, max_files: 16]}}
```

The same option works with `Executors.Bubblewrap`; capture happens in the host
without adding sandbox mounts. Preparation includes the directory and limits
in approval details and creates no files. Model arguments cannot raise these
limits. The directory must be inside the workspace.

When inline output is truncated, `output_retention` reports a workspace-relative
`path` readable with `ReadFile`, retained `bytes`, observed `total_bytes`, and
whether the file is also `truncated`. Files contain the first `max_bytes` raw
stdout/stderr bytes, including binary output. Small outputs release their slots.
Retention failure or exhausted slots returns `output_retention.error` alongside
the ordinary command result; exit status and timeout behavior remain unchanged.

Atomic reservations cap storage at `max_files * max_bytes` for one directory
using consistent host limits. Existing slots and reported files are never
overwritten or automatically evicted. Hosts remove entire `slot-*` directories
after their consumers finish; killed collectors can leave partial slots, but
their file descriptors close with the collector. These also count against the
quota. Do not change limits or remove active slots while commands are running.

## Verify

```sh
mix test --max-cases 4
mix compile --warnings-as-errors
```

Local builds use sibling checkout dependencies. To build a distribution with
Hex dependency requirements, use `ALTO_HEX_BUILD=1 mix hex.build`. This builds
the archive locally; it does not publish a release. Build core first, then
contrib when preparing a coordinated release. The TUI currently uses a source
build because of its native dependency compiler workaround.

See the [repository guides](../../docs/README.md) and
[composition examples](../../examples/README.md).

For explicit reuse of pinned upstream `SKILL.md` directories and their supporting
files, see the [upstream skills example](../../examples/upstream_skills/README.md).
It composes the existing prompt and workspace tools without maintaining a skill
catalogue.

## Cache warming during tools

Native Anthropic callers can opt in without changing core or global defaults:

```elixir
result = Alto.Contrib.CacheWarmer.run("Review the repository", options,
  max_requests: 3,
  max_duration_ms: 900_000
)
```

`options` must select `Alto.Contrib.Providers.Anthropic`. `start/3` returns an
ordinary Alto handle. Warming protects only this execution's last successful
normal request while its tools run; shared-session children and compaction do
not replace it. Timers and in-flight requests stop with the run, cancellation,
owner death, or the finite horizon.

Refreshes use the provider's zero-output prewarming API, preserving tools,
messages and cache-sensitive options. Thinking, structured output and forced
selection requests are skipped. OpenAI-compatible endpoints are intentionally
unsupported until their replay and retention behavior have a dedicated adapter.

These are **additional paid requests**, separately bounded by `max_requests`,
`request_timeout_ms` (10 seconds), `max_duration_ms`, and `max_prompt_bytes`
(1 MB). `refresh_margin_ms` defaults to 30 seconds before the configured
5-minute or 1-hour TTL. No retention or savings guarantee is made: cache misses
still bill input, and a miss/error stops that candidate. The live
`cache_warm_finished` event reports separate canonical usage, or `usage_unknown`
when a cancelled/failed attempt cannot report billing. It does not alter model
step limits, normal run usage, or the transcript; billing collectors should
include these events.

The lifecycle approach is informed by [OMP's cache warmer](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/session/cache-warmer.ts).
The transport follows [Anthropic's native prewarming protocol](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#pre-warming-the-cache).
