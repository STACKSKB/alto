# Configuring Alto

Alto takes an ordinary Elixir keyword list for each run. An `alto.exs` is a
trusted Elixir program that returns that list. It can call functions, import
shared configuration, read environment variables, and construct custom modules
or callbacks. Keep as many config files as your workflows need; the filename is
a convention, and `--config` accepts any path.

## Defaults and config selection

`Alto.default_config()` returns the library defaults. Use `Keyword.merge/2` or
`Alto.default_config(overrides)` to change them. Nested values are replaced;
there is no implicit deep merge.

Library defaults include an empty tool list, a deny policy for approvals, serial
tool execution, and bounded execution. Providers and credentials are supplied
by the caller. The CLI adds read-only file tools, the coding prompt, project
instructions, interactive approvals, and session persistence when those entries
are omitted. If you pass a complete default config, its explicit entries take
precedence over those CLI additions.

The CLI selects configuration in this order:

1. `--config FILE`.
2. The `ALTO_CONFIG` environment variable.
3. `$XDG_CONFIG_HOME/alto/config.exs`, or `~/.config/alto/config.exs`.
4. CLI defaults when none of the above exists.

`--no-config` skips the environment and per-user config. It cannot be combined
with `--config`. Alto does not automatically execute a workspace's `alto.exs`.
The TUI uses its `--config` argument, defaulting to `alto.agentic.exs` relative
to its working directory; pass an explicit path when running from another folder.

## A small profile

Save this as `alto.exs` for read-only model-assisted work:

```elixir
Alto.default_config()
|> Keyword.merge(
  tools: [Alto.Tools.ListFiles, Alto.Tools.ReadFile, Alto.Tools.SearchFiles],
  prompt: &Alto.Prompts.Coding.build/1,
  project_instructions: :auto,
  max_steps: 48,
  run_timeout: 30 * 60 * 1_000
)
```

```sh
mix alto --config alto.exs "Explain this repository"
```

With no `provider` entry, the CLI resolves OpenRouter from `ALTO_API_KEY`,
`OPENROUTER_API_KEY`, or the private credential store created by
`mix alto --setup`. `ALTO_MODEL` overrides that store's default model.
An explicit `provider` is used as supplied, including its credentials and model;
set `provider: nil` for a providerless rule loop.

## Multiple models and sessions

For example, keep shared settings beside several workflow profiles:

```text
profiles/
  base.exs
  review/alto.exs
  chat/alto.exs
  local/alto.exs
```

`profiles/base.exs` can contain the small profile above. Each child evaluates it
relative to its own file, then overrides the values it needs.

`profiles/review/alto.exs` selects a model and credentials explicitly:

```elixir
{base, _binding} = Code.eval_file(Path.expand("../base.exs", __DIR__))

Keyword.merge(base,
  provider:
    {Alto.Providers.OpenAICompatible,
     base_url: "https://openrouter.ai/api/v1",
     api_key: System.fetch_env!("OPENROUTER_API_KEY"),
     model: System.fetch_env!("ALTO_REVIEW_MODEL")}
)
```

`profiles/chat/alto.exs` removes tools and uses a conversational prompt:

```elixir
{base, _binding} = Code.eval_file(Path.expand("../base.exs", __DIR__))

Keyword.merge(base,
  loop: Alto.chat_loop(),
  tools: [],
  prompt: &Alto.Prompts.Chat.build/1,
  project_instructions: nil
)
```

`profiles/local/alto.exs` points at a local OpenAI-compatible server:

```elixir
{base, _binding} = Code.eval_file(Path.expand("../base.exs", __DIR__))

Keyword.merge(base,
  provider:
    {Alto.Providers.OpenAICompatible,
     base_url: "http://localhost:1234/v1",
     model: System.fetch_env!("ALTO_LOCAL_MODEL")}
)
```

Select one for each run, or set a default for the current shell:

```sh
mix alto --config profiles/review/alto.exs "Review this change"
mix alto --config profiles/chat/alto.exs "Help me think through the design"
export ALTO_CONFIG=/absolute/path/to/profiles/local/alto.exs
mix alto "Explain the parser"
```

One-shot CLI runs save sessions and print their IDs. List them with
`mix alto --sessions`, and select the desired config for each follow-up:

```sh
mix alto --resume SESSION_ID --config profiles/review/alto.exs "Check error handling too"
```

A resumed run resolves its provider, tools, approvals, and limits from the
selected config. Its system prompt comes from saved history; changing `prompt`
or project instruction files does not replace that history. Config files are
not embedded in sessions. Use `--no-session` for a one-shot run without
persistence. See [conversation revisions](conversations.md) for recovery and
branching.

To use a profile with `mix alto.tui --config FILE`, include a native backend in
its keyword list, for example:

```elixir
Keyword.put(base, :tui_backends, [alto: {Alto.TUI.Backends.Native, []}])
```

For several selectable providers in one TUI, configure `provider_profiles`;
its provider and model pickers remember choices across tasks. See the
[TUI guide](../packages/alto_tui/README.md#providers-and-backends).

## Coding tools and execution policy

The supplied [`alto.agentic.exs`](../alto.agentic.exs) is a complete coding
profile. It adds edits, approved Git mutations, sandboxed shell/argv execution,
parallel reads, context reduction, and agent tools. Use it directly or evaluate
it as a base for your own profile:

```elixir
{coding, _binding} = Code.eval_file("/absolute/path/to/alto/alto.agentic.exs")
Keyword.merge(coding, max_steps: 64, run_timeout: 60 * 60 * 1_000)
```

Tools, permissions, and sandbox mounts are explicit configuration. The supplied
profile protects `.git` from ordinary file edits and commands, and gives Git
mutation its own approved tool. Bubblewrap commands have a writable workspace,
a read-only runtime, a fresh temporary directory, and network disabled by
default. Executor `network: :inherit` enables network access;
`Alto.Command.Executors.Unsandboxed` selects host execution.

Set `approval: &Alto.Approval.interactive/2` for terminal decisions or
`approval: :approve` for an explicitly trusted unattended workflow. Custom
callbacks can make policy decisions from the prepared request. See
[extensions](extensions.md#approval-decisions) for those contracts.

## Prompts, context, and limits

`prompt` accepts a builder or text; `prompt: nil` omits the configured system prompt.
With `project_instructions: :auto`, a fresh CLI or TUI task loads the first
existing root instruction file, `alto.md` then `AGENTS.md`, up to 32,000 bytes.
Nested instructions are read by the agent rather than automatically injected.
Use `project_instructions: nil` to disable this input.

`loop` selects the control policy. `Alto.default_loop/1` supports tool batches,
context admission, middleware, and subagents. `Alto.chat_loop/1` disables tool
execution; `Alto.rule_loop/1` runs deterministic tool steps; `Alto.loop/2` accepts
a custom loop. Context reduction is opt-in and configured separately through
`compaction`. See [loops](loop-contract.md), [tool batches](tool-batches.md),
[context reduction](context-reduction.md), and [subagents](subagents.md).

| Setting | Scope |
| --- | --- |
| `run_timeout` | Whole execution tree, including descendants |
| `max_steps` | Model steps in a run |
| `provider_timeout` | Each supervised provider call |
| `tool_timeout` | Each supervised tool call |
| `approval_timeout` | Waiting for an approval decision |
| `max_tool_result_bytes` | Retained tool result size |
| `max_transcript_bytes` | Model transcript size |
| `max_events`, `max_event_bytes` | In-memory event retention |

Timeouts are milliseconds. HTTP providers also accept `timeout` for a total
request deadline and `idle_timeout` for stream silence. Set `provider_timeout`
above the HTTP deadline if the transport should report its own timeout first.
Config changes apply when a run starts or resumes.

`provider_retries` bounds retries before any model output is delivered; it is
zero by default. The transient policy honors provider retry hints, keeps waiting
cancellable, and stops rather than waiting through a delay longer than 60 seconds.
An attempt that has already streamed output is not automatically replayed.

## Library and resident hosts

Library calls take the same keyword list, with a provider supplied by the host:

```elixir
{:ok, options} = Alto.Config.load("profiles/review/alto.exs")
result = Alto.run("Review the parser", options)
```

`mix alto --serve --config FILE` exposes the selected config as `"default"`.
Add `runs` for named overrides and `sessions: true` to persist served runs:

```elixir
Keyword.merge(base,
  sessions: true,
  runs: %{
    "review" => [max_steps: 48],
    "chat" => [loop: Alto.chat_loop(), tools: [], prompt: &Alto.Prompts.Chat.build/1]
  }
)
```

Here `base` is the previously constructed keyword list. A client selects a
configured name in `start_run`; it cannot submit executable Elixir or arbitrary
run overrides. Each named list is merged into the base options. See the
[front-end protocol](../PROTOCOL.md) and [execution hosts](runners.md).
