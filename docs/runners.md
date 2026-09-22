# Execution hosts and reusable components

`Alto.Runner` is the host behaviour and dispatcher. Use `runner: MyRunner` in
`Alto.Config.new/1`, `Alto.run/2`, or `Alto.start/2`; Serial remains the default.
`runner_options:` carries trusted host-specific configuration. Both are
inherited by child runs. A runner owns scheduling and its private handle.

Every host implements `run/2`, `start/2`, `await/2`, `cancel/2`, `terminate/2`,
and `subscribe/2`. The public dispatcher wraps private handles in the opaque
`Alto.Runner.Handle`. Outcomes use `Alto.Runner.Result`:

```elixir
{:ok, handle} = Alto.start(task, runner: MyRunner, tools: tools, loop: loop)
{:ok, reference} = Alto.subscribe(handle)

receive do
  {:alto_runner_result, ^reference, outcome} -> inspect(outcome)
end
```

After a successful subscription, exactly one completion notification must be
delivered, including process failure and subscription after completion. Await
timeouts return `{:error, :await_timeout}` without cancelling execution.
`cancel/2` requests cooperative cancellation; `terminate/2` is the fallback
after the caller's grace period and must preserve uncertainty about dispatched
operations. Hosts must honor execution bounds and the optional `owner:` lifetime.

The optional `Alto.Runner.TaskHost` implements this lifecycle with supervised
tasks. Handles can be observed and awaited by different processes; results are
retained for 60 seconds after completion. Registry and TUI maintain their own
result/history retention. A host may instead use external jobs or another
process model: clients must not inspect the underlying handle.

## Manual execution

`Alto.Runner.Serial` executes effects immediately by default. Manual mode lets
an external controller admit each effect for inspection and orchestration:

```elixir
{:ok, handle} = Alto.start(task,
  runner: Alto.Runner.Serial,
  runner_options: [mode: :manual, controller: self()],
  loop: loop,
  tools: tools,
  approval: approval_policy
)

receive do
  {:alto_step_ready, ticket, %{next_effect: kind}} ->
    IO.puts("Next effect: #{kind}")
    Alto.Runner.Serial.advance(ticket)
end
```

Continue handling tickets until the completion notification arrives. Each
ticket admits one frame; duplicate or stale tickets cannot advance another.
Stepping does not approve a tool: the configured approval policy still runs.
Waiting consumes the deadline and stays cancellable. Controller exit cancels
the run. Child runs inherit the runner options and may issue their own tickets.

## Composition

The built-in scheduler uses `Alto.Runner.Execution.run/3` to assemble a run
and `step/2` to execute at most one effect. A scheduler receives an opaque
context and a frame, and chooses when to call `step/2`. It must return the
terminal outcome so the assembly can persist the session and child result.
`check/1` and `abort/2` support schedulers which wait between effects.

The lower-level components can also be used independently:

| Component | Responsibility |
| --- | --- |
| `Execution.Tool` | Exact preparation, approval, and direct invocation inside supervised workers |
| `ToolBatch` | Bounded worker invocation for single calls and concurrent groups |
| `Execution.Model` | Provider context checks, streaming, and bounded retries |
| `Execution.Transcript` | Bounded history and optional compaction |
| `Execution.Events` | Event retention, persistence, and outcome accounting |
| `Execution.Session` | Transcript revision checks and final session records |
| `Execution.Children` / `SubagentBatch` | Inherited authority, retained child continuations, bounded concurrency, joining |
| `Execution.Workspace` | Optional resource setup/capture around a worker callback |
| `Execution.Call` | Supervised invocation with deadline and cancellation |
| `Runner.Budget` | Shared execution-tree accounting |
| `Persistence.Codec` / `Persistence.Retained` | Bounded serialization and revision-fenced storage operations |

Execution components consume the fields required by each operation.
`Execution.Setup.open/2` assembles the run map; independent callers can supply
the required capabilities directly. Components do not call Serial.

Shared hosts use the same versioned checkpoint continuation format. A custom
host using a different interpreter must define its own compatible continuation
contract or reject checkpoint input; it must never silently start over.

These are execution mechanisms. Task/team policy, model assignment, messaging,
memory, and skill formation remain application responsibilities.

## Retained resources in application hosts

`Subagents.Continuation.lookup/3` and
`Runner.Budget.Account.lookup/3` return `{:ok, handle, snapshot}` from one
validated ledger entry. They never initialize missing records or issue grants.
`Continuation.list/3` discovers cells by a literal metadata subset and returns
their identities and snapshots. Each API accepts an optional absolute monotonic
`deadline:`; account handles do not retain that per-operation deadline.

For approval displays, `Continuation.inspect_approval(batch, revision, child_id)`
returns the selected approval and its revision from one snapshot. Another
operator may change the continuation afterwards: a decision must still carry that
viewed revision and the returned child identity.

Applications choose which resources belong to a task, whether a budget account
is shared, and when terminal work may be cleaned up. Those decisions should use
the public lookup/read and generation-fenced retirement APIs rather than
reconstructing handles from private operation-log envelopes. Discovery does not
authorize execution, replacement-generation adoption, or automatic retries of
uncertain effects.
