# Shared interactive input

An interactive host can attach a bounded channel to any shared execution host:

```elixir
{:ok, input} = Alto.Input.start_link(max_messages: 32, max_bytes: 64_000)
{:ok, run} = Alto.start("Inspect this project", input: input, provider: provider)
Alto.Input.put(input, "Focus on the parser", :steer)
Alto.Input.put(input, "Then explain the change", :follow_up)
Alto.await(run)
```

Steering arrives before the next model request once outstanding tool calls have
settled. Follow-ups arrive when the loop would otherwise finish. Neither mode
cancels or conceals already dispatched work. A live provider call continues to
its boundary; use ordinary run cancellation when immediate termination is
needed.

Delivery appends a user message and emits `:input_received` through the existing
loop middleware. The default loop starts another model step. Custom loops decide
how to react to that event. Follow-ups share the original run's model/effect
budgets and deadline; delivery never refreshes them.

Each channel has one active consumer, preventing concurrent runs from inserting
the same message. Messages are acknowledged only after transcript insertion;
failed insertion leaves them queued. A channel outlives a consumer crash, if its
own host remains alive, and can be attached to a later run. `Alto.Input.list/1`
reports pending entries. The channel itself is in memory, so hosts needing
durable ingress should retain submissions in their application store.

An accepted enqueue is not a promise of delivery: a run may finish or exhaust
its budget before consuming it. Hosts should inspect pending entries on
completion and decide whether to start another run. Checkpoints do not serialize
the channel; the host explicitly supplies it again on resume.

In the optional TUI, Enter queues a native Alto follow-up while a run is active,
and Ctrl+Enter submits native steering input for the next model boundary. Input
accepted near completion, cancellation, or failure remains pending until the
next eligible run; the TUI keeps the composer draft and lets Enter retry
delivery. Existing custom and Codex backends keep their established local
follow-up queues and controls.
