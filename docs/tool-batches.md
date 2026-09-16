# Explicit tool batches

The coding loop can request bounded concurrent calls as ordinary configuration:

```elixir
Alto.Config.new(
  loop: Alto.default_loop(tool_execution: {:parallel, 4}),
  tools: tools,
  provider: provider
)
```

`Alto.Effect.run_tools(calls, concurrency)` exposes the same mechanism to other
trusted loops. Both shipped execution hosts understand the effect. The default
loop still emits serial calls unless configured otherwise.

Only tools declaring both `execution_mode: :parallel` and `approval: :never`
run concurrently. Other calls divide the batch into ordered groups and execute
through the normal preparation/approval boundary. Each group has at most the
requested concurrency (1–32). Thus reads before a write finish before its
approval or execution, and later reads see the result of that write.

Preparation and shared effect-budget admission are coordinated before group
dispatch. Every dispatched worker has its own deadline and bounded result;
the maximum buffered native result data scales with concurrency times the
configured result limit. This is a per-run concurrency cap, distinct from
subagent concurrency. Descendants still share the execution budget.

Workers never modify loop or transcript state. The coordinator records all
group outcomes in source order, then dispatches completion events through
middleware in that order. Effects requested by these handlers execute after
the group settles. This is an explicit semantic boundary: ordinary individual
tool effects retain their existing interleaved hook behavior.

Cancellation terminates outstanding workers and records their uncertain
outcomes. Hard coordinator death terminates workers through ownership monitors.
Tools are not automatically retried. Approval checkpoints occur at serial
barriers and retain the remaining batch groups.
