# Context reduction policies

Compaction is composed from a trigger, a reducer, and an allowance:

```elixir
Alto.Config.new(
  loop: Alto.default_loop(context: Alto.Context.window(compact_at: 0.85)),
  compaction: [strategy: :handoff, max_compactions: 8, keep_recent_messages: 12],
  sessions: true
)
```

`compact_at` is an optional fraction of the model's input budget (after output
reservation). Crossing it attempts reduction before a request is dispatched.
This soft threshold is advisory: when reduction is disabled, exhausted, or
ineffective, a request still fitting the hard window can proceed. A hard
context-window failure attempts reduction too, but never sends an oversized
request. Transcript byte overflow remains an independent trigger.

Trusted loops can emit `Alto.Effect.compact_context/1` for manual reduction.
Independent hosts can call `Alto.Runner.Execution.Transcript.reduce/2` directly.
The optional `required_headroom` specifies how many transcript bytes must fit
afterwards. A successful reduction must strictly shrink the retained context;
each success consumes the configured compaction allowance. Provider reductions
also consume the shared model budget. Compaction never refreshes deadlines or
execution budgets, and its count is preserved in approval checkpoints.

Compaction is disabled by default. When enabled, the default allowance is one
reduction per run. Custom reducers may use
the existing supervised request/decode contract, or implement deterministic
`Alto.Context.Compaction.reduce/3` without a provider. A session is required to
retain the facts replaced by a reduction. Complete call/reply groups and recent
messages remain intact.

Use `Alto.Context.Estimator` with a configured tokenizer and provider/model
framing costs when available. The default byte estimator remains conservative;
admission estimates and authoritative provider usage are separate measurements.

### Prefix reuse and cache accounting

Ordinary tool turns append assistant/tool messages to the stored conversation.
The initial system prompt and tool definitions remain fixed, and resuming a
session reuses its saved messages verbatim. Compaction intentionally replaces
older history; changing models, tools, or reasoning settings can also invalidate
provider cache reuse.

The shipped `alto.agentic.exs` enables `usage_estimation: true` in its context
window policy. After a successful response, an exactly unchanged message/tool
prefix is budgeted using the provider's reported input tokens, with every new
suffix byte charged as one token plus message framing. A changed prefix falls
back to the existing byte estimate. Explicit tokenizers take precedence. This
avoids repeatedly treating the entire observed code transcript as one token per
byte and compacting too early. Initial/resumed requests without an observation
still use the conservative byte fallback.

OpenRouter requests carry a stable session ID for provider affinity. Native
Anthropic and Claude through OpenRouter enable automatic five-minute prefix
caching by default; set provider option `prompt_cache: false` to opt out, or
`prompt_cache: %{"type" => "ephemeral", "ttl" => "1h"}` to request a longer TTL.
Explicit request cache controls take precedence. Other compatible endpoints do
not receive these provider-specific fields. Cache retention, routing, minimum
prompt lengths, and actual hits remain provider-controlled.

The Alto status bar reports both the last request's cache read percentage and
the cumulative percentage, so cold starts and earlier misses do not obscure
current reuse. Internal compaction streams produce context-progress events,
not assistant messages; decoded handoff artifacts remain the durable record.

Provider references:
- https://openrouter.ai/docs/guides/best-practices/prompt-caching
- https://platform.claude.com/docs/en/build-with-claude/prompt-caching
