# Extension boundaries

Alto keeps application choices at explicit boundaries. A host can add hooks
around lifecycle events, configure trusted commands, transform model supplied
tool input, select an optional renderer or front end, and choose provider
adapters without changing the runner.

## Package contracts

Core contains the execution engine and shared contracts. Optional implementations
live in `alto_contrib`; UI state and task navigation live in `alto_tui`. Contrib
and TUI import core, and core never imports either application. The independent
core build and compiled-module boundary tests enforce this direction.

Trusted tools declare `runtime_operation/1` to bind owned delegation or messaging
semantics independently of their module or model-visible name. The runtime still
owns admission, approval, cancellation, inherited authority and accounting.
Hosts provide `agent_prepare` (`fn(prepared, policy_context, tool_options)`),
`agent_models` (`fn(arguments, policy_context, tool_options)`) and
`child_provider_resolver` (`fn(profile_key, model, policy_context)`) callbacks
when those policies are needed. The trusted policy context includes the current
run's provider and registered tools; model discovery also receives its ordinary
tool context. These fields follow child provider selection and narrowed tool
scopes. Ordinary tools receive a bound discovery callback, without provider
configuration in their context map. Contrib composes its provider catalog
implementation through these callbacks.

`Alto.Resource` defines retained child-resource acquisition, use, freezing,
recovery and stable identity. `Alto.Contrib.Workspaces` implements it for Git
workspaces; execution does not inspect its struct or backend modules. Retained
resources remain trusted host choices, subject to the shared deadline,
authority and checkpoint boundaries.

## System prompts

The `:prompt` run option accepts literal text, `nil` to omit the system message,
or a function receiving the prompt context. For example, use
`prompt: "Answer concisely"` or `prompt: &Alto.Contrib.Prompts.Coding.build/1`.
Capture options in a closure, such as
`prompt: &Alto.Contrib.Prompts.Chat.build(&1, identity: "Answer concisely.")`.
CLI runs read this option from the selected configuration file.
A resumed conversation retains its stored system message.

## Request diagnostics by composition

The executor emits `model_started` with the step number only. Request diagnostics
are ordinary provider composition in the selected configuration file, not a
runner option. For example, `alto.agentic.exs` observes its OpenRouter provider:

```elixir
require Logger

provider =
  Alto.Provider.observe({Alto.Contrib.Providers.OpenAICompatible, provider_options}, fn request ->
    report = Alto.Contrib.Providers.PrefixContinuity.report(request)
    Logger.debug(fn -> "Alto prefix continuity: #{inspect(report)}" end)
  end)
```

Use this `{module, options}` provider specification in the run options or a
provider profile. A bare module means `{module, []}`; provider options belong
inside the tuple.
Omit observation to omit diagnostics; nest calls to compose observers.
Observers run for each transport attempt (including retries and reduction),
inside the provider's existing timeout and cancellation boundary. They receive
the request unchanged and select their own output destination. Their output
does not count as streamed model output or suppress retries. Observer exceptions
are isolated; a slow observer still consumes the provider call's time budget.
Direct hosts stream observed specifications through `Alto.Provider.stream/4`
and use `Alto.Provider.options/1` before calling description or discovery callbacks.
The configured module remains the actual provider.
Only the prefix report is content-free; arbitrary observers receive full requests
and are trusted configuration code. Description, model discovery, model selection
and credentials pass through to the wrapped provider.

## Transforming tool input

`Alto.Tool.transform/2` configures a host-side input transform on a normal tool
specification and applies a two argument function `(arguments, context)` once,
when the invocation is prepared. The transformed arguments are included in the
approval details and the resulting opaque value is passed unchanged through
approval to execution.

```elixir
path_transform = fn args, context ->
  {:ok, Map.put(args, "path", Path.expand(args["path"], context.cwd))}
end

tools = [
  Alto.Tool.transform(Alto.Contrib.Tools.ReadFile, path_transform)
]
```

The wrapped tool retains its name, schema, approval requirement, and execution
mode. Prepared tools keep their own `prepare` and `run` callbacks. A
run-only tool receives the transformed argument map through the same
preparation boundary. Nested transforms run outermost first; approval details
show the final transformed arguments. Keep transforms deterministic and local; authorization
should describe the value that will be executed.

Built-in argument contracts use `use Alto.Tool, arguments: true` and an
`arguments(opts)` callback returning `{description, nimble_options_schema}`.
That declaration supplies both the model-visible schema and validation before
domain preparation. Required fields, defaults, types and configured bounds have
one definition; unknown keys are rejected without creating atoms from input.
The small `Alto.Tool.Arguments` projection supports the types used by these
tools. Custom and remote tools can continue supplying their own `schema/1`.
Registration keeps runtime metadata and each provider definition together.
Model exposure projects that registry in tool-name order, intersected with the
parent's exposure when delegated. Reordering configured tools does not reorder
the provider schema.
Text contracts enforce UTF-8 byte limits; the schema's character ceiling is a
conservative projection, so multibyte strings can reach the byte limit sooner.

Direct hosts must call `Alto.Tool.prepare(module, arguments, context, opts)`
before invoking `module.run(prepared, context, opts)`. Module `prepare/3` and
`run/3` are callbacks inside that boundary. A transform crosses the same boundary
after changing input. File snapshots and other opaque prepared values pass
unchanged to execution; they are not interpreted as argument maps again.
`Alto.Tool.run/4` combines preparation and execution for direct hosts. It runs
callbacks in the caller; runner execution supplies approval and supervision.

## Typed content

Use `Alto.Content` for a user task, a provider's block-list response, or a tool's
typed result. Ordinary tool maps and lists keep JSON text behavior even if they
contain keys such as `type` or `data`. Constructors return provider-neutral maps
with string keys. The wrapper, transcript and session all use those same blocks.

```elixir
{:ok, file} = Alto.Contrib.Attachment.upload("report.pdf")
{:ok, block} = Alto.Contrib.Attachment.content(file)
task = Alto.Content.new([Alto.Content.text("Summarize this report"), block])
Alto.run(task, provider: provider)
```

`Alto.Contrib.Attachment.update/2` edits staged text at its existing path; `content/1`
reads its current bounded contents. `paste/2` splits UTF-8 text into byte-bounded
files, preferring line boundaries and preserving every byte. Submission must
freeze the resulting blocks; persisted content embeds bytes and never depends
on a mutable staging path.

`Alto.Content.file(name, media_type, base64)` represents model-facing input.
`Alto.Content.artifact(name, media_type, base64)` represents downloadable output;
requests see its file description, while history retains the bytes. Add
`Alto.Contrib.Tools.PublishFile` to snapshot bounded workspace-confined files as artifacts.
Materialized outputs use a stable digest, so replay reuses paths and saved native
history can recreate missing files. Hosts own staging retention and cleanup.

The runner calls `Alto.Content.normalize_tool_result/2` before inserting typed
content. `Alto.Content.decode_transcript/1` validates and wraps blocks for the
provider; provider-specific source maps are built only for the request. See
[configuration](configuration.md#generated-files-and-images) for provider transports,
image generation and host limits, and [interactive input](interactive-input.md#typed-messages)
for queued content.

### Model-facing tool images

```elixir
content = Alto.Content.new([
  Alto.Content.text("Screenshot after the change"),
  Alto.Content.image("image/png", base64_data, 1280, 720)
])
```

`Alto.Contrib.Tools.ReadImage` reads workspace-confined PNG and JPEG files. It reads no
more than the configured base64 limit permits, recognizes the format from file
bytes, validates PNG header integrity or JPEG frame dimensions, and rejects
images above the configured dimension or pixel limits. It returns an
`Alto.Content` image block with base64 data; it does not invoke a shell command
or require an image package.

```elixir
tools: [
  {Alto.Contrib.Tools.ReadImage,
   max_encoded_bytes: 1_000_000,
   max_dimension: 8_192,
   max_pixels: 20_000_000}
]
```

The tool accepts optional `max_width` and `max_height` arguments. A requested
downsize fails with `:image_resize_unavailable` unless the tool is configured
with a `processor:` function taking `(bytes, media_type, width, height)` or an MFA
`{module, function, extra_arguments}` that returns `{:ok, encoded_bytes}`.
Processor output is sniffed and
checked against the byte, dimension, pixel, and requested-size limits before it
is returned.

Image delivery is opt-in at the provider as well. Declare the selected model's
inputs using [provider capabilities](configuration.md#attachments-and-model-inputs).
Both HTTP adapters reject unsupported image blocks before dispatch. OpenAI Chat Completions tool messages permit text only,
so that adapter keeps all correlated tool replies textual and appends one user
image message after the complete contiguous tool-reply group. Each base64 data
URL has its source tool call ID in an adjacent text part. Anthropic requests
receive native base64 image-source blocks inside the correlated tool result.

The default `max_tool_result_bytes` still applies to the native typed value.
Set that runner bound high enough for the configured encoded-image limit. The
reader supports only PNG and JPEG, and resizing needs an explicitly configured
backend.

The typed-content contract independently caps custom image blocks at 8 MB of
base64, 16,384 pixels per dimension, and 40 million pixels. It decodes the
bounded payload, sniffs its PNG/JPEG metadata, and requires the actual media
type and dimensions to equal the block's declared values. This also covers
typed image results produced by custom tools.

## Approval decisions

The `approval` run option accepts a decision literal (`:approve`, `:suspend`, or
`{:deny, reason}`) or a two-argument function receiving the display-safe
approval request and tool context maps. Use closures to bind
options. Built-in prompts are `&Alto.Contrib.Approval.interactive/2` and
`&Alto.Contrib.Approval.socket/2`. `Alto.Contrib.Approval.delegated/3` can be wrapped in a
closure when it needs options.

The runtime projects tool contexts through `Alto.Tool.context/1`: `session_id`,
`cwd`, `metadata`, `agent_identity`, `messaging`, `input`, `input_reader`,
`messaging_tools`, and `budget`. Absent optional capabilities are nil; provider
configuration is excluded. Standalone callers can supply a map containing the
fields needed by the tool. Approval requests carry all fields of
`Alto.Approval.request()`, including their distinct operation and correlation IDs.

```elixir
approval = fn request, context -> MyPolicy.decide(request, context, policy_opts) end
Alto.run(task, approval: approval)
```

`:approve` authorizes the prepared operation, `:suspend` captures it for a
checkpoint-capable host, and `{:deny, reason}` returns the reason as the tool
failure. The default policy is `{:deny, :policy_denied}`.

## Usage accounting

Provider adapters decode wire usage in contrib and return canonical fields.
Execution normalizes canonical usage with `Alto.Usage.normalize/1` and carries
one atom-keyed accounting map through results, events, checkpoints and front ends.
The map includes cumulative counts, latest-request counts, a context window and
`requests`. A present `requests` field identifies serialized accounting; otherwise
normalization treats the value as one provider response. `Alto.Usage.merge/2` adds
cumulative fields and replaces latest-request fields only when the right-hand map
reports a request. Codex cumulative snapshots use `Alto.Contrib.Usage.from_codex/1` and
retain `requests: 0` because the server does not provide a request count.

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

context = Alto.Context.Window.new(
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

For text-only Chat Completions runs, contrib's
`Alto.Contrib.Providers.OpenAICompatible.estimate_text_context/1` can be used as
the estimator. It reuses the provider codec so published artifacts count as
file references rather than base64 payloads. The full artifact still counts
toward runtime result and transcript byte limits. Media input needs a
model-appropriate estimator; this helper does not tokenize images or audio.

## Hooks, commands, and clients

Middleware is an ordered list of three-argument functions `(event, context, next)`.
Call `next.(event)` to continue the chain and return a
`{terminal, loop_state, effects}` transition. See the [loop contract](loop-contract.md).
Use closures to bind options, or capture a reusable module function:

```elixir
middleware = fn event, context, next -> MyMiddleware.call(event, context, next, options) end
loop = Alto.default_loop(middleware: [middleware])
loop = Alto.Loop.after_event(loop, :step_settled, fn event, context -> effects(event, context) end)
```

`after_event/3` accepts a two-argument function returning ordered effects. Its
effects precede the inner transition's effects; middleware still enters in list
order and unwinds in reverse. Malformed trusted callbacks fail under supervision.

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

Command `:policy` is a function `(arguments, context)` returning
`{:ok, invocation_map}` or `{:error, reason}`, a portable `{module, function,
extra_arguments}` tuple, or a literal `{:error, reason}` denial. MFA callbacks
receive arguments and context before the extra arguments. Use this data form
when a narrowed child tool profile must survive a durable checkpoint. The default is
`&Alto.Contrib.Command.resolve/2`, which validates bounded arguments and resolves the
requested program before approval. Capture options in a closure to restrict it:

```elixir
allowed = ["git", "printf"]
policy = fn arguments, context ->
  if arguments["program"] in allowed,
    do: Alto.Contrib.Command.resolve(arguments, context),
    else: {:error, :program_not_allowed}
end
```

The invocation map contains `requested_program`, the resolved `executable`,
`args`, `cwd`, `timeout_ms`, and `max_output_bytes`. Command preparation freezes
this map and asks the configured executor to prepare it before approval.
`:executor` remains `{module, keyword_options}`. The prepared map contains
`executor`, its opaque `execution` value, and display-safe `approval_details`;
execution uses that frozen value without resolving PATH again. Bubblewrap's
execution value is a map containing `invocation` and `sandbox`.

These are trusted host callbacks: contract violations raise; policy rejection
and execution failures return errors. RunCommand's schema and default resolution
share the argument contract. Scalar and list validation returns
`NimbleOptions.ValidationError`; executable lookup, NUL bytes, and aggregate argv
size retain their command-specific errors.

The library keeps executor selection explicit. `Alto.Contrib.Command` still defaults to
`Unsandboxed` for trusted host workflows. CLI configurations opt in by including
`Alto.Contrib.Tools.RunCommand` with the chosen executor in `tools:`. The shipped coding
profile selects Bubblewrap with networking disabled and existing `.git` metadata
read-only.
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
Alto.Contrib.Tools.ProtectPaths.wrap(Alto.Contrib.Tools.WriteFile, [".git"])
Alto.Contrib.Tools.ProtectPaths.wrap(Alto.Contrib.Tools.EditFile, [".git"])
```

The wrapper rejects lexical and resolved targets within protected paths, including
symlink aliases, while retaining the wrapped tool's approval and frozen preparation
contracts. Unwrapped tools retain their workspace-wide behavior. The CLI and
coding profile use these wrappers; custom hosts select their own paths and tools.

## Per-tool resource limits

Compose limits with tool specifications in the host's `alto.exs`:

```elixir
tools: [
  {Alto.Contrib.Tools.WriteFile, max_bytes: 512_000, preview_bytes: 2_048},
  {Alto.Contrib.Tools.EditFile, max_file_bytes: 2_000_000, max_edits: 50},
  {Alto.Contrib.Tools.ReadFile, max_bytes: 32_000},
  {Alto.Contrib.Tools.ListFiles, max_entries: 200},
  {Alto.Contrib.Tools.SearchFiles, max_files: 500, max_matches: 50, max_line_graphemes: 200}
]
```

File tools merge trusted host overrides with their default option maps once
at registration or standalone preparation. Model arguments remain subject to the
host's ceilings. Prepared writes and edits retain these limits with the
approved operation. Larger tool limits may also require a larger runner result
budget. Search additionally accepts `max_entries`, `max_file_bytes`,
`max_query_bytes`, and `excluded_directories`; directory exclusions are a `MapSet`.
Search accepts `backend: fn(request, context) -> {:ok, result_map} end`; `nil`
uses the bounded native traversal. The request contains atom-keyed `:query`,
`:path`, and `:case_sensitive` fields. Custom backends own their traversal bounds
and workspace confinement. Image resizing accepts
`processor: fn(bytes, media_type, width, height) -> {:ok, encoded_bytes} end`;
returned bytes are revalidated before model delivery. Both callbacks can instead
be `{module, function, extra_arguments}`; invocation appends the extra arguments
to the callback inputs. Use portable MFA arguments in explicit durable child
tool profiles; inherited callbacks may use functions.

Custom tools can implement `options/0` to supply a default map. Their callbacks
receive the merged map; tools without it receive their configured keywords.
Use `Alto.Tool.prepare/4` or `Alto.Tool.run/4` for standalone invocations.

## Retained subprocesses

MCP and Codex server options, and `Alto.Contrib.Tools.FFF.tools/1`, accept an `executor:` using the same
`Alto.Contrib.Command.Executor` contract as command tools. Executors may implement the
optional `open(prepared, transport_options)` callback, returning an
`Alto.Contrib.External.Process`. Forward transport options, including `:line` for bounded
OTP line framing. MCP and Codex `max_message_bytes` limits count JSON payload bytes,
excluding LF or CRLF. They reject oversized or unterminated frames before decoding.
The shared JSON-RPC host owns request deadlines and process lifetime. An executor without `open/2`
fails closed; Alto never falls back to host execution. Client reuse includes the executor and its options in its key.
Existing custom executors implementing only `prepare/2` and `execute/1` continue
to work for ordinary command tools.
Server argv comes from trusted host configuration; model-facing command argument
limits do not apply.

```elixir
sandbox = {Alto.Contrib.Command.Executors.Bubblewrap,
  network: :disabled, protected_paths: [".git"],
  env: %{"MY_TOOL_SETTING" => "value"}}

Alto.Contrib.Tools.FFF.tools(command: "/usr/local/bin/fff-mcp", executor: sandbox)
{Alto.Contrib.Tools.Ripwire, executable: "/usr/local/bin/ripwire", executor: sandbox}
```

Put sandbox environment variables in the executor's `env:` option. Bubblewrap
rejects additional transport-level environment overrides after preparation.
Unsandboxed servers retain their server-level `env:` option. FFF and Ripwire
remain unsandboxed unless a host selects an executor; the shipped coding profile
selects Bubblewrap for both, exposes the selected executable read-only, and gives
it a temporary home. Additional language runtimes or caches outside `/usr` and
`/etc` require explicit mounts. Missing sandbox support is an error, not a fallback.

## Project instruction inputs

Contrib hosts interpret `project_instructions: :auto` by loading `alto.md` or
`AGENTS.md`. A contrib host can instead
provide `[files: ["CUSTOM.md"], max_bytes: 16_000]`, or `nil` to disable discovery.
Candidates must resolve inside the workspace and be regular files. The loader
reads only the configured prefix plus four bytes for UTF-8 boundary handling,
rejects malformed retained text, and marks truncation. It does not scan or validate
the omitted tail. Prompt builders remain replaceable, and resume retains the
stored prompt rather than reloading these files. Core accepts `nil`, an explicit
instructions map, or a one-argument loader returning `{:ok, map | nil}`. It has
no project-file discovery policy.

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
| `loop.context` | `%{check: fn(request, provider_info)}` | `Alto.Context.Window.new/1` |
| `loop.subagents` | Limits map with `admit: fn(agents, context)` | `Alto.Subagents.bounded/1` |
| `compaction[:strategy]` | `Alto.Context.Reducer.compact/3` | `Reducers.Summary`, `Reducers.Handoff` |
| `retry_policy` | `fn(reason, attempt)` | `&Alto.Contrib.Retry.Transient.decide/2` |
| `tool_presenter` | `fn(name, arguments)` | `&Alto.Contrib.ToolDisplay.summary/2` |

Context and child policies are maps containing functions. Capture host state in
closures. A context check returns `{:ok, :unavailable}`, `{:ok, budget}` with a
nonnegative `:reserve_output` and optional boolean `:pressure`, or `{:error, reason}`.
`nil` disables context admission. These are trusted callback contracts; malformed
configuration may fail under supervision.

`Subagents.bounded/1` validates child limits and accepts an `:admit` function
returning `:ok` or `{:error, reason}`. Admission cannot expand inherited tool
authority. To select limits for each run, supply a zero-argument factory returning
the policy map; execution calls it once under the tool deadline and cancellation
boundary. The resolved limits also determine the agent tools' advertised schema.

```elixir
children = Alto.Subagents.bounded(
  max_depth: 2,
  max_children: 8,
  max_concurrency: 4,
  admit: fn agents, context -> MyPolicy.admit(agents, context, settings) end
)
loop = Alto.default_loop(subagents: children)
```

Reducers receive structured pinned, middle and recent messages, historical tool
schemas, limits and artifact metadata, plus a bounded model-call function. They
return `{:ok, %{content: text, data: map, events: list, records: list}}`. Execution
forces `tool_choice: :none`, accounts model calls, and checks replacement size,
shrinkage and headroom before accepting it. Custom reducers use this same
structured `compact/3` contract.
Built-in reducers use the same module configuration as host reducers.

```elixir
retry_policy: &Alto.Contrib.Retry.Transient.decide(&1, &2, base_delay: 100, max_delay: 2_000),
tool_presenter: &Alto.Contrib.ToolDisplay.summary/2,
compaction: [strategy: {Alto.Contrib.Context.Reducers.Handoff, []}]
```

A retry callback returns `:stop` or `{:retry, delay_ms, reason}`. Execution still
refuses to replay an attempt after output delivery and enforces the attempt and
time budgets. Contrib supplies the transient retry policy. Bare core stops retries without
an explicit policy;
`provider_retries: 0` disables retries. Omitted presentation emits the tool name.
Completion events retain the native result in `value`; consumers render it with
`Alto.Contrib.ToolDisplay` or their own presentation function. Tool-title presenter failures
fall back to the tool name; presentation cannot change tool input or authorization.

`Alto.Events.combine/1` composes synchronous sinks in order, isolating sink
failures. CLI, registry and TUI delivery attach their host sink before the
application sink, preserving host backpressure. Request diagnostics are composed
with `Alto.Provider.observe/2` in the profile; the core executor has no
prefix-continuity dependency.

Slow host observers can opt into `Alto.Events.with_buffered/3`:

```elixir
{result, delivery} = Alto.Events.with_buffered(observer,
  [max_events: 128, max_bytes: 2_000_000, callback_timeout: 250, drain_timeout: 5_000],
  fn buffered -> Alto.run(task, event_sink: buffered) end)
```

The owner must inspect `delivery` before claiming successful observer delivery.
Admission acknowledges bounded queue ownership; it does not acknowledge callback
completion. Accepted events run in order on one supervised callback at a time.
Only adjacent queued live text/reasoning deltas with identical attribution may
coalesce; durable events keep their individual position. Queue overflow rejects
admission and appears in the drain result. A callback exception or deadline also
appears there and later events continue in order. Nothing silently drops an
accepted durable event. A timed-out drain reports failure and ends the observer's
ownership; durable session storage remains the execution host's responsibility.
The owner exiting terminates the dispatcher and its callback. For longer-lived
ownership use `Alto.Events.Observer.open/2`, `sink/1` and `close/2` directly.
A synchronous observer still consumes the provider deadline; attempt diagnostics
record accumulated callback time and any active callback at termination.

NimbleOptions now owns context-window, child-limit and compaction option schemas.
Authority relationships and domain-specific validation remain explicit.

## Webhook admission

Webhook endpoints are a map from HTTP paths to trusted callback settings.
Closures capture their configuration; admission helpers are ordinary functions.

```elixir
{Alto.Contrib.Listeners.Webhook,
 endpoints: %{
   "/hooks/events" => %{
     verify: &Alto.Contrib.Ingress.HMAC.verify(&1, &2, secret: secret),
     identity: &Alto.Contrib.Ingress.IdentityHeader.extract(&1, header: "x-delivery-id"),
     on_event: fn key, payload -> Alto.Queue.request(queue, {:admit, key, payload, []}) end,
     max_body_bytes: 262_144
   }
 }}
```

`verify.(body, headers)` returns `:ok` or `{:error, reason}`; verification covers
exact body bytes before admission. `identity.(headers)` returns
`{:ok, delivery_id}` or `{:error, reason}`. Headers are a list of name/value pairs.
The listener bounds body size and delivery identity. `source` defaults to the
endpoint path; admission receives `source <> ":" <> delivery_id` and
`%{"delivery_id" => delivery_id, "body" => body}`.

Bandit assembles chunked bodies under the supplied byte limit and applies the
socket read timeout. Ingress helpers trust their configuration; malformed
configuration can raise, while request signatures and delivery IDs remain
validated. HMAC secrets must be nonempty binaries.

An admission function returns `{:ok, record}` only after durably establishing
identity and work, or `{:error, reason}`. A duplicate is acknowledged with HTTP
200; full admission returns 503 and oversized payloads return 413. Exceptions,
exits, and malformed admission replies remain failures rather than acceptance.
Bandit handles these failures at the HTTP boundary.
The host owns I/O timeouts, supervision, retention, and worker retries. A database
host may commit the identity row and execution job in one transaction, as the
[Oban example](../examples/oban_backend/README.md) does. Successful admission is
not a promise of successful execution or permission to retry uncertain effects.

For shallow dispatch, use `on_event: {:start_run, "configured-name"}` instead.
That path uses bounded resident delivery deduplication and starts the configured
run with the body as its task; durable admission remains the callback's concern.
