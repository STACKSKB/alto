# Extension boundaries

Alto keeps application choices at explicit boundaries. A host can add hooks
around lifecycle events, configure trusted commands, transform model supplied
tool input, select an optional renderer or front end, and choose provider
adapters without changing the runner.

## Request diagnostics by composition

The executor emits `model_started` with the step number only. Request diagnostics
are ordinary provider composition in the selected configuration file, not a
runner option. For example, `alto.agentic.exs` wraps its OpenRouter provider:

```elixir
require Logger

provider =
  Alto.Providers.Observe.wrap({Alto.Providers.OpenAICompatible, provider_options}, fn request ->
    report = Alto.Providers.PrefixContinuity.report(request)
    Logger.debug(fn -> "Alto prefix continuity: #{inspect(report)}" end)
  end)
```

Use this provider specification in `Alto.Config.new/1` or a provider profile.
Omit the wrapper to omit diagnostics; nest wrappers to compose observers.
Observers run for each transport attempt (including retries and reduction),
inside the provider's existing timeout and cancellation boundary. They receive
the request unchanged and select their own output destination. Their output
does not count as streamed model output or suppress retries. Observer exceptions
are isolated; a slow observer still consumes the provider call's time budget.
Only the prefix report is content-free; arbitrary observers receive full requests
and are trusted configuration code. Description, model discovery, model selection
and credentials pass through to the wrapped provider.

## Transforming tool input

`Alto.Tools.Transform` is a host-side input adapter. It wraps a normal tool
specification and applies a two argument function `(arguments, context)` once,
when the invocation is prepared. The transformed arguments are included in the
approval details and the resulting opaque value is passed unchanged through
approval to execution.

```elixir
path_transform = fn args, context ->
  {:ok, Map.put(args, "path", Path.expand(args["path"], context.cwd))}
end

tools = [
  Alto.Tools.Transform.wrap(Alto.Tools.ReadFile, path_transform)
]
```

The wrapped tool retains its name, schema, approval requirement, and execution
mode. Prepared tools keep their own `prepare` and `run_prepared` callbacks. A
run-only tool receives the transformed argument map through the wrapper's
preparation boundary. Keep transforms deterministic and local; authorization
should describe the value that will be executed.

## Context estimates

`Alto.Context.Window` accepts a unary estimator. `Alto.Context.Estimator` adapts
a tokenizer function and adds provider and model framing values:

```elixir
estimator =
  Alto.Context.Estimator.new(
    tokenizer: &MyTokenizer.count/1,
    provider_overhead: 16,
    message_overhead: 4,
    tool_overhead: 8,
    model: "claude-sonnet-4-5",
    model_overhead: %{"claude-sonnet-4-5" => 12}
  )

context = Alto.Context.window(
  max_tokens: 200_000,
  reserve_output: 16_000,
  estimator: estimator
)
```

The tokenizer receives the JSON representation of each message and tool
definition. Framing values account for provider and model request structure.
Neither the default byte tokenizer nor a custom tokenizer is an exact provider
count unless the host calibrates it against the selected model and request
shape. Provider usage remains authoritative after a request completes.

## Hooks, commands, and clients

Lifecycle hooks observe typed events and may record metrics or project state.
They do not replace approval or execution boundaries. Command tools should use
the configured command executor: sandboxed commands are appropriate for model
requested work, while unsandboxed commands belong to explicitly trusted host
workflows and should be configured with narrow permissions.

Renderers are optional front ends. The CLI, TUI, WebSocket, and protocol clients
consume the same events and approval handles; a host can provide another
renderer without changing tools or providers. Provider adapters are also
optional dependencies at the application boundary. A host can select a native
adapter or an OpenAI-compatible endpoint and keep credentials, retries, and
provider-specific setup outside the core execution contract.

## Composable isolation and protected paths

The library keeps executor selection explicit. `Alto.Command` still defaults to
`Unsandboxed` for trusted host workflows; the CLI requires `--allow-command` for
that authority. `--sandbox-command` and the shipped coding profile select
Bubblewrap with networking disabled and existing `.git` metadata read-only.
Ordinary workspace files remain writable. This protects metadata, not all work
against deletion; hosts can select `workspace: :read_only` or isolated workspaces.

Bubblewrap accepts `protected_paths: [".git", "other-metadata"]`, relative to the
workspace. These read-only mounts are applied after configured writable mounts.
Paths escaping the workspace or resolving through symlinks are rejected. Missing
paths are skipped without creating host files. A Git worktree's `.git` file is
protected, but its external Git directory is not automatically exposed. Hosts
must configure additional mounts explicitly when they need that directory.
`protected_paths: []` retains unrestricted workspace writes. The dedicated,
approval-required Git mutation tool in the coding profile uses that explicit
setting; ordinary command and analysis tools keep `.git` protected.

Native file tools can apply the same policy through the existing transform seam:

```elixir
Alto.Tools.ProtectPaths.wrap(Alto.Tools.WriteFile, [".git"])
Alto.Tools.ProtectPaths.wrap(Alto.Tools.EditFile, [".git"])
```

The wrapper rejects lexical and resolved targets within protected paths, including
symlink aliases, while retaining the wrapped tool's approval and frozen preparation
contracts. Unwrapped tools retain their workspace-wide behavior. The CLI and
coding profile use these wrappers; custom hosts select their own paths and tools.

## Per-tool resource limits

Compose limits with tool specifications in the host's `alto.exs`:

```elixir
tools: [
  {Alto.Tools.WriteFile, max_bytes: 512_000, preview_bytes: 2_048},
  {Alto.Tools.EditFile, max_file_bytes: 2_000_000, max_edits: 50},
  {Alto.Tools.ReadFile, max_bytes: 32_000},
  {Alto.Tools.ListFiles, max_entries: 200},
  {Alto.Tools.SearchFiles, max_files: 500, max_matches: 50, max_line_graphemes: 200}
]
```

NimbleOptions validates these host options. Model arguments remain subject to the
host's ceilings. Prepared writes and edits retain the validated limits with the
approved operation. Larger tool limits may also require a larger runner result
budget. Search additionally accepts `max_entries`, `max_file_bytes`,
`max_query_bytes`, and `excluded_directories`; existing defaults are unchanged.

## Retained subprocesses

MCP server options and `Alto.Tools.FFF.tools/1` accept an `executor:` using the same
`Alto.Command.Executor` contract as command tools. Executors may implement the
optional `open(prepared, transport_options)` callback, returning an
`Alto.External.Process`. MCP owns framing, request deadlines, message limits and
process lifetime. An executor without `open/2` fails closed; Alto never falls back
to host execution. Client reuse includes the executor and its options in its key.
Existing custom executors implementing only `prepare/2` and `execute/1` continue
to work for ordinary command tools.

```elixir
sandbox = {Alto.Command.Executors.Bubblewrap,
  network: :disabled, protected_paths: [".git"],
  env: %{"MY_TOOL_SETTING" => "value"}}

Alto.Tools.FFF.tools(executable: "/usr/local/bin/fff-mcp", executor: sandbox)
{Alto.Tools.Ripwire, executable: "/usr/local/bin/ripwire", executor: sandbox}
```

Put sandbox environment variables in the executor's `env:` option. Bubblewrap
rejects additional transport-level environment overrides after preparation.
Unsandboxed MCP retains its existing server-level `env:` option. Both adapters
remain unsandboxed unless a host selects an executor; the shipped coding profile
selects Bubblewrap for both, exposes the selected executable read-only, and gives
it a temporary home. Additional language runtimes or caches outside `/usr` and
`/etc` require explicit mounts. Missing sandbox support is an error, not a fallback.

## Project instruction inputs

`project_instructions: :auto` loads `alto.md` or `AGENTS.md`. A host can instead
provide `[files: ["CUSTOM.md"], max_bytes: 16_000]`, or `nil` to disable discovery.
Candidates must resolve inside the workspace and be regular files. The loader
reads only the configured prefix plus four bytes for UTF-8 boundary handling,
rejects malformed retained text, and marks truncation. It does not scan or validate
the omitted tail. Prompt builders remain replaceable, and resume retains the
stored prompt rather than reloading these files.

Provider adapters can honor the protocol-neutral request hint `tool_choice: :none`
while retaining schemas needed by historical tool messages. The built-in
OpenAI-compatible and Anthropic adapters translate it to their respective wire
formats. Built-in context reduction uses this hint with transcript requests;
custom adapters can use `request_mode: :isolated` until they support it. No reducer
response dispatches tools through the execution host.

## Composing execution policies

Compose these values in the relevant `alto.exs`. Execution owns cancellation,
shared budgets, authority checks and persistence; the selected component owns
its policy decision. Built-in implementations use the same callbacks as host code.

| Configuration | Contract | Shipped implementation |
| --- | --- | --- |
| `loop.context` | `Alto.Context.Policy.check/3` | `Alto.Context.Window` |
| `loop.subagents` | `Alto.Subagents.Policy.limits/1`, `admit/3` | `Alto.Subagents.Bounded` |
| `compaction[:strategy]` | `Alto.Context.Reducer.compact/3` | `Reducers.Summary`, `Reducers.Handoff` |
| `retry_policy` | `Alto.Retry.decide/3` | `Alto.Retry.Transient` |
| `tool_presenter` | `Alto.ToolPresentation.summary/3` | `Alto.ToolDisplay` |

Context and child policies accept either an implementing struct or
`{Module, options}`. A context check returns `{:ok, :unavailable}`, a budget map
with a nonnegative `:reserve_output` and optional boolean `:pressure`, or an
error. Invalid implementations and malformed results are rejected. Child limits
are normalized with NimbleOptions before execution enforces them; admission
cannot expand inherited tool authority.

Reducers receive structured pinned, middle and recent messages, historical tool
schemas, limits and artifact metadata, plus a bounded model-call function. They
return `{:ok, %{content: text, data: map, events: list, records: list}}`. Execution
forces `tool_choice: :none`, accounts model calls, and checks replacement size,
shrinkage and headroom before accepting it. Legacy text `reduce/3` and
`request/3` + `decode/3` reducers still work through `Reducers.Legacy`.
`:summary` and `:handoff` remain compatibility aliases; new profiles can name the
implementations explicitly.

```elixir
retry_policy: {Alto.Retry.Transient, base_delay: 100, max_delay: 2_000},
tool_presenter: {Alto.ToolDisplay, []},
compaction: [strategy: {Alto.Context.Reducers.Handoff, []}]
```

A retry callback returns `:stop` or `{:retry, delay_ms, reason}`. Execution still
refuses to replay an attempt after output delivery and enforces the attempt and
time budgets. Omitted retry policy preserves the existing transient policy;
`provider_retries: 0` disables retries. Omitted presentation emits the tool name.
The optional `result/2` presenter callback supplies a preview for typed content;
without it, `output` is empty and `value` retains the content. Presenter failures
fall back to the tool name or an empty preview; presentation cannot change tool input
or authorization.

`Alto.Events.combine/1` composes synchronous sinks in order, isolating sink
failures. CLI, registry and TUI delivery attach their host sink before the
application sink, preserving host backpressure. Request diagnostics are composed
with `Alto.Providers.Observe.wrap/2` in the profile; the core executor has no
prefix-continuity dependency.

NimbleOptions now owns context-window, child-limit and compaction option schemas.
Authority relationships and domain-specific validation remain explicit.
