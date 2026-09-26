# Loop contract

A loop implements `Alto.Loop.init/2` and `handle_event/3`. It receives typed
`Alto.Event` values and returns plain tuples describing the next state and work.
The runtime executes that work; loops and middleware do not call providers or
tools directly. Configure a loop with `Alto.loop(MyLoop, options)`.

## Transitions

A transition is `{terminal, loop_state, effects}`:

```elixir
{:continue, state, [{:request_model, %{}}]}
{{:stop, output}, state, []}
{{:error, reason}, state, []}
```

`terminal` is `:continue`, `{:stop, result}`, or `{:error, reason}`. Effects are
an ordered list. A terminal transition may include effects to execute before
settling; it discards the previously pending tail of effects. Effects already
collected from earlier events in the same completed batch still precede those
requested by its terminal handler. A continuing frame that drains without
requesting further work fails
with `:loop_stalled`.

## Effects

Each effect is `{kind, payload}`. There are no effect or transition constructors.

| Effect | Payload and purpose |
| --- | --- |
| `{:emit, event}` | An `Alto.Event` directly; record and dispatch it through the loop and middleware. |
| `{:request_model, request}` | A map of model request settings interpreted within the run's configured provider and tool authority. |
| `{:compact_context, options}` | A map requesting bounded reduction through the configured reducer; `%{}` uses the manual reduction defaults. |
| `{:run_tool, call}` | A model-shaped call with `arguments_json`, decoded once by the host. |
| `{:run_tools, %{calls: calls, max_concurrency: limit}}` | An explicit ordered batch of model-shaped calls, with concurrency from 1 through 32. |
| `{:invoke_tool, call}` | A native `%{name: binary, arguments: map}` call, optionally carrying `id` for loop/event correlation. |
| `{:spawn_agents, request}` | A bounded child batch such as `%{agents: [%{id: "research", task: "Find evidence"}]}`. |

A model request may include `context_message` to append trusted-loop context as
a user message before requesting the model. The transcript byte bound applies;
this cannot change roles or grant tool capabilities. Context reduction may
include `required_headroom` to specify how many transcript bytes must fit after
reduction. See [context reduction](context-reduction.md).

Native invocations avoid a JSON round trip. Their outcomes enter provider
history as explicit context, never as replies to provider tool calls. Both
invocation forms retain preparation, approval, execution bounds, and supervision.
Provider call IDs are correlation identifiers; the runtime assigns operation
identities for execution and approval tracking.

Only tools declaring `execution_mode: :parallel` and `approval: :never` run
together within a batch. Other calls form barriers: earlier reads settle before
a write is approved or executed, and later reads observe the write. Completion
hooks run in source order after each bounded parallel group settles. Individual
`run_tool` effects retain interleaved completion-hook semantics. See
[tool batches](tool-batches.md) and [subagents](subagents.md).

## Middleware and scheduling

Middleware receives `(event, context, next)` and returns the same transition
tuple. It enters in configured list order and unwinds in reverse. To prepend
work returned by the inner handler:

```elixir
{terminal, state, effects} = next.(event)
{terminal, state, additional_effects ++ effects}
```

`Alto.Loop.after_event/3` performs this composition for hooks returning ordered
effects. Hook work precedes the inner transition's effects.

A scheduler receives a frame `{effects, terminal}` and an execution context.
`Alto.Runner.Execution.step/2` executes at most one effect and returns either
`{:continue, next_frame, next_context}` or `{:done, outcome}`. The scheduler
chooses when to step and must return the terminal outcome so session and child
results can be persisted. `check/1` and `abort/2` support cancellable waiting.
Frame tuples describe scheduling; loop transitions additionally carry loop state.
See [execution hosts](runners.md) for manual admission and host lifetimes.
