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
