# Alto subagents

Subagents are requested by a trusted loop through an effect. A single child
uses `Alto.Effect.spawn_agent/1`; a bounded batch uses
`Alto.Effect.spawn_agents/1`:

```elixir
defmodule FanoutLoop do
  @behaviour Alto.Loop

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Transition

  @impl true
  def init(%{jobs: jobs}, _spec) do
    agents = Enum.map(jobs, fn {id, task} -> %{id: id, task: task} end)
    Transition.continue(%{}, [Effect.spawn_agents(%{agents: agents})])
  end

  @impl true
  def handle_event(%Event{type: :subagents_completed, data: data}, state, _spec) do
    Transition.stop(state, data.results)
  end

  @impl true
  def handle_event(_event, state, _spec), do: Transition.continue(state)
end

Alto.run(%{jobs: [{"a", "first task"}, {"b", "second task"}]},
  loop: Alto.loop(FanoutLoop,
    subagents: Alto.Subagents.bounded(
      max_depth: 1,
      max_children: 8,
      max_concurrency: 3
    )
  ),
  provider: MyProvider)
```

`spawn_agents/1` accepts `%{agents: [...]}`. Each entry has the same spawn
fields as `spawn_agent/1`: required `:id` and `:task`, with optional provider,
loop, tools, model tools, maximum steps, and system prompt. IDs must be unique.
The batch preserves input order in `data.results`, even when children finish in
a different order. A completed child result has `id`, `status`, `output`, `error` when applicable,
`reason` for cancellation, `model_requests`, `usage`, `outcome`, `run_id`, `session_id`, and an optional `workspace` resource reference.
A child that could not start has only `id`, `status: :error`, and `error`. The single-child events are `:subagent_completed` or
`:subagent_failed`; a batch emits one `:subagents_completed` event containing
`%{results: results}`.

`Alto.Subagents.bounded/1` is Alto's policy constructor. `max_children` limits
one batch (default 16, range 1–64), while `max_concurrency` limits active children
in that batch (default 1, at most `max_children`). `max_depth` limits recursive
delegation; children cannot widen their inherited absolute depth allowance.
Batch concurrency is per loop, not a global service-wide limit. The entire
execution tree also remains subject to the root's shared budget.

The root run owns one shared effect counter, model-request counter, and
monotonic deadline. Children and batches consume those same counters and
deadline, so a batch cannot multiply the root allowance by its child count.
The child’s local `max_steps` remains an additional per-child limit.


### Durable count budgets

Trusted hosts can back the shared effect and model-request counters with an
`Alto.OperationLog`. Each execution tree should use one account key:

```elixir
alias Alto.Runner.Budget.Account
{:ok, ledger} = Alto.OperationLog.start_link(
  id: "budgets", name: nil, dir: "/private/alto-state/operations")
{:ok, account} = Account.open(ledger, "tree-123",
  max_effects: 1000, max_model_requests: 80)

Alto.run(task, budget_account: account, loop: loop, provider: provider)
```

The caller supervises the ledger. A run and its children consume the same
account; sharing it across additional runs intentionally shares one allowance.
Each successful reservation appends and syncs a revision-fenced counter update
before granting permission to dispatch. Both counters are read in one coherent
snapshot. Reopening an account preserves its generation and counters; caps can
only become tighter. Previously created handles also obey a tightened cap.

Approval snapshots include the account key and generation. The restoring host
must reopen and supply that same account through `budget_account:`. Restore
uses the current durable counts, including charges made after the snapshot;
it never clones the snapshot's remaining allowance. Missing/replaced accounts,
an observed counter rollback or ledger failure reject restoration/reservation.
The legacy in-memory counter path remains the default. Separate child
checkpoints are still disabled: durable counts alone do not recover child
dispatch, active execution time, or parent joins.

This account persists count limits only. The existing monotonic run deadline
and root checkpoint's remaining active time keep their current semantics;
waiting for a supported root approval still pauses that run's active time.
Coordinating active time across independently parked children remains pending.
Model-request limits count requests, not tokens or currency.

Reservations are not refunded when a callback fails, cancellation arrives or
the deadline expires after the durable charge. If a write or reply is uncertain,
the caller gets no dispatch permission; a reservation may nevertheless remain
consumed. Repeating an old reservation call is not an execution retry grant.
Counters are bounded admission state rather than a billing ledger.

After the execution tree has ended, a host can read `Account.read(account)` and
call `Account.close(account, revision)`. Closure rejects future reservations
through old handles and records a terminal ledger outcome, allowing normal
index eviction. It does not cancel already dispatched callbacks. Closure uses
a second ledger attempt, so the ledger must allow at least two attempts. A
crash during closure leaves a non-active retained operation for review; it
cannot silently reopen with zero counters. Reusing an evicted key creates a new
generation that cannot restore an old snapshot.

Active accounts cannot be evicted. The operation ledger's configured record,
operation and log-size bounds still apply; log exhaustion denies reservations.
`OperationLog.update_checkpoint/4` is the generic primitive used here: it
replaces active retained data at an expected revision without releasing the
checkpoint or granting an execution attempt. Application code remains
responsible for its own retained-data schema and authority. Older Alto readers
reject the new `checkpoint_update` record kind instead of skipping charges.

Runtime tools are capabilities of the parent. An explicit child tool list must
be an exact normalized subset of the parent list; a module and `{Module, []}`
are equivalent. A child can narrow model exposure, but cannot add a tool or
replace a parent tool with another module under the same name. Approval and
tool bounds continue to be enforced by the host.

The parent owns each child handle, and a guardian monitors the parent process.
Explicit cancellation cancels all active children and allows one five-second
grace period for the whole batch before forced cleanup. Parent process death
also triggers cooperative cancellation through the guardians. Queued batch
entries are never started during cancellation. Child provider, tool, and loop failures become child
result data rather than crashing the parent. An uncertain child effect keeps
the parent result verdict at `:unknown`, even if the loop chooses an otherwise
successful output.

Children inherit transcript and tool-result bounds. The combined batch result
must also fit the parent's `max_tool_result_bytes` bound before delivery to the
loop; its serialized user-context message must fit the transcript bound. A
result-limit failure does not undo effects the children already performed. Aggregate descendant usage is merged into the root
`Result.usage`; `Result.model_requests` remains the root’s own model-step
count, while each child result reports its own model requests.

Delegated system prompts may be supplied with `system_prompt`, up to 64,000
bytes, and override the inherited system prompt for that child. The child task
does not get to alter runtime capabilities through prompt text. A trusted loop
may also add a bounded `context_message` to a model request; Alto records it as
a user message and validates it under the transcript limit.

## Durable child dispatch and retained joins

A trusted host can enable an `Alto.OperationLog` journal on its subagent policy:

```elixir
{:ok, ledger} = Alto.OperationLog.start_link(
  id: "children", name: MyChildJournal, dir: "/private/alto-state/operations")
policy = Alto.Subagents.bounded(
  max_depth: 1, max_children: 4, max_concurrency: 2, journal: MyChildJournal)
```

The policy covers single-child and batch effects. Descendants inherit the
journal along with their shared budgets and owned lifetime. A run-scoped
operation key identifies each batch. Its immutable metadata contains the
parent run/session and execution-tree identity; child IDs retain input order.
The parent emits `subagents_started` with a portable `journal` binding. Normal
single-child and batch completion data also includes that binding.

Alto persists a unique dispatch ticket before starting each child. The child
itself records its bounded result after session persistence and workspace
capture, before returning to its parent. This retains the exact native child
summary (including output, verdict, usage, session/workspace links and
persistence status), even when the parent cannot collect its reply. The journal
does not store the child's full transcript or arbitrary loop state. Failure to
retain a result keeps the dispatch uncertain and prevents a successful join.
Queued cancellation records known non-dispatch separately; it cannot overwrite
a dispatched child.

Completed results remain nonterminal retained checkpoints. Ledger pressure
cannot evict them before a parent acknowledges consumption and explicitly
retires the batch. A host can use the generic API directly:

```elixir
alias Alto.Subagents.Journal
{:ok, batch} = Journal.restore(MyChildJournal, saved_binding)
{:ok, joined} = Journal.join(batch)
# joined.results is an ordered list of {child_id, exact_result} pairs.
# First durably save the consumer's continuation with this binding/results.
{:ok, acknowledged} = Journal.acknowledge(batch, joined.revision,
  %{"parent_checkpoint" => durable_checkpoint_id})
:ok = Journal.retire(batch, acknowledged.revision)
```

`acknowledge/3` fences the viewed revision and accepts a nonempty JSON receipt;
the host is responsible for that receipt referring to its durable continuation.
The runner does not automatically acknowledge a join merely because its loop
received an event or a best-effort session write succeeded. Acknowledgement
alone retains the results. Retirement uses a second ledger attempt and makes
the batch eligible for normal terminal eviction. If retirement is interrupted,
read its current revision and finish `retire/2`; this performs only ledger
updates, never child execution. Reusing an evicted key creates a new generation,
so old parent bindings and dispatch tickets cannot attach to the replacement.

For custom hosts, `open/4` creates/reconnects a batch from ordered unique IDs
and immutable JSON metadata. `dispatch/2` grants a planned child once;
`complete/2` retains a portable result under that ticket, and `skip/3` records a
planned child's known non-dispatch. Exact repeated result publication is
idempotent; conflicting results are rejected. A lost dispatch reply does not
permit redispatch. `read/1` exposes planned, dispatched and completed children;
`join/1` returns results only when every child has a retained outcome. A
completed result can still describe an uncertain external effect: its verdict
remains authoritative and joining it grants no retry permission.

Results use the existing exact checkpoint codec, capped at 64,000 bytes per
native result. Nonportable values fail closed. Decoding loads Alto's fixed runner/usage vocabulary and does not create atoms;
trusted code defining additional result atoms must already be loaded in the
restoring VM. Stored data never selects modules to load. The whole batch must also fit the ledger's checkpoint/record/log limits,
so applications may need a larger `max_recovery_bytes`/`max_record_bytes` for
multiple large results. Exhaustion can prevent saving a result after execution;
the dispatch then remains uncertain. Private storage is required because exact
outputs can contain sensitive data. Prefer a stable registered ledger name in
policies whose configuration must match across runner checkpoint restoration.

This option provides durable dispatch records and recoverable join data. It
does not automatically recreate a parent's pending batch continuation, restart
planned children, independently suspend/resume children, or coordinate active
time across parked participants. A recorded dispatch without a result remains
uncertain after restart and is never blindly rerun. These lifecycle mechanisms
remain separate work; session replay alone cannot supply them.

## Child sessions

The default `sessions: :shared` policy keeps child audit events in the parent's
session log. Only the parent owns that session's transcript sidecar. A trusted
host can instead select independent child logs and transcript snapshots:

```elixir
Alto.Subagents.bounded(
  max_depth: 1, max_children: 4, max_concurrency: 2, sessions: :separate)
```

When the parent has a session, each child receives a fresh session ID in the
same private session directory. Completed child results expose `session_id`;
the parent's durable completion event retains these links. Child startup
records retain `parent_session_id`, `parent_run_id` and the host-derived
`agent_identity`. Separate children own their transcript revision and listing
summary, while keeping `subagent: true` as ancestry metadata. Session summaries
include parent-session and execution-tree identity links. A parent without
persistence does not create child logs even when separate sessions are selected.
The policy applies to the children of that loop; a recursively delegating child
chooses its own session policy through its trusted loop specification.

Separate child conversations are readable after completion without mixing
sibling transcripts or changing the parent's transcript. Shared budgets,
tool/depth authority and owned cancellation remain unchanged. Persistence is
still best effort: child logging failures propagate as degraded persistence in
the parent result. A session is not a durable dispatch or join ledger. A crash
before the parent records a result can leave a child log with only its backward
link; applications must not infer execution or retry eligibility from it.

Checkpoints remain root-only. Independently suspended children, shared active-time accounting and
recovered parent joins are not implemented by this option. Durable count
budgets are a separate opt-in mechanism described above. Checkpoint fingerprints include the subagent policy and tool
configuration, so changing those trusted settings invalidates an old packet.


## Execution-tree identity

Every serial tool context and result contains `agent_identity`, a map with
`root_run_id` and `path`. A root starts with its current run ID and an empty
path. Child paths append their spawn ID, so a grandchild can be addressed as
`["parser", "tests"]` within the same root. Spawn request data cannot replace
this identity. Internal host options are trusted configuration, not model input.
Identity paths are bounded to 64 nonempty UTF-8 segments of at most 256 bytes;
root IDs are nonempty UTF-8 strings of at most 256 bytes.

Exact checkpoint capture saves the identity and exposes a JSON summary in the
packet. Restore checks that summary against saved state and restores both the
result and live tool context identity. The resumed execution has a new current
run ID but keeps its original root namespace. A completed-session follow-up
starts a fresh namespace. Applications can use this to scope local mailboxes
without letting a model choose its sender identity. Identity does not itself
start a mailbox, authorize a recipient, persist child execution or isolate a
workspace; these remain separate policies and mechanisms.

`Alto.Queue.claim_matching/5` provides an optional generic storage primitive
for addressed consumers. A bounded exact map selector filters payload fields
inside the atomic claim operation, before applying existing due-time, FIFO,
wire-byte and lease rules. Unrelated records are not claimed. The queue remains
one bounded store; applications define envelopes, addresses and authorization.


## Isolated coding workspaces

A host can opt a bounded subagent policy into independent Git checkouts:

```elixir
{:ok, ledger} = Alto.OperationLog.start_link(
  id: "workspaces", name: nil, dir: "/private/alto-state/operations", max_ops: 128)
manager = Alto.Workspaces.new(
  root: "/private/alto-state/workspaces", ledger: ledger)
policy = Alto.Subagents.bounded(
  max_depth: 1, max_children: 4, max_concurrency: 2, workspaces: manager)
# Use policy as the parent loop's :subagents option.
```

The host captures one clean source commit before admitting the batch. Each
execution-tree child identity gets its own local clone, object store and index.
The runner sets the child's tool cwd; a spawn request cannot choose another
cwd. Descendants inherit the manager along with existing authority and budgets.
Use a unique child ID for each assignment within a root execution: an already
used workspace is retained for review and cannot execute that assignment again.

The built-in Git backend requires an ordinary repository with a `.git`
directory and a clean source checkout. Dirty sources, linked source worktrees,
submodules, source-local filters, alternates and symlinked paths are rejected
explicitly. Ignored build output is neither cloned nor captured; it does not consume checkout bounds.
Source bytes, file counts, checkout bytes, patch bytes and command time are
bounded. Host-global Git configuration and inherited Git environment are
excluded; hooks and external diff commands are disabled.

Git metadata lives beside the checkout, outside the directory exposed to file
tools. A frozen patch also lives outside that directory and is checked against
its recorded hash whenever read. These are separate writable workspaces, not
an operating-system security sandbox: unrestricted commands and custom tools
retain their configured authority. Use an appropriate command executor when
process-level filesystem or network isolation is required.

Creation, worker use and patch capture are resource operations in the existing
`Alto.OperationLog`. Dispatch is recorded before mutation. Ready, worked and
frozen resources are nonterminal checkpoints and cannot be evicted to make room
for another workspace. A process crash leaves its unfinished operation visible;
Alto does not repeat it automatically. A grant interrupted before dispatch is
also retained for review. Cooperative child cancellation releases its lock
once the runner has stopped, while uncertain workspace failures propagate an
unknown verdict to the parent.

Completed child results contain a `workspace` map with its ID, revision,
status and metadata, including the source commit and frozen patch hash.
`Alto.Workspaces.get/2` inspects it; `patch/2` returns the bounded immutable Git
diff. Hosts can also use `prepare/2`, `create/3`, `use/4` and `freeze/3` directly
with an optional backend implementing `snapshot/2`, `checkout/3` and `diff/3`.
`prepare/2` returns an `Alto.Workspaces.Snapshot` carrying the expanded source
separately from provider-owned metadata. A backend that supports reviewed
integration may additionally implement `prepare_apply/4`, `verify_apply/4`
and `apply/4`; the manager supplies the retained source to verification and
dispatch, treats their results as opaque bounded JSON and
propagates post-dispatch `{:unknown, reason}` outcomes. A backend must return
bounded JSON snapshot metadata and cannot supply runtime credentials in that
metadata.

`discard/4` requires the viewed revision and an explanatory note. It holds the
same operating-system resource lock as worker use, so cleanup cannot remove a
live worker's files. Interrupted resources remain cleanup obligations until
explicitly discarded. Workspace storage survives ledger restart; it does not
make the child run independently resumable. Applying a patch to the lead's
checkout remains a separate reviewed integration operation; capture never
modifies the source checkout.
