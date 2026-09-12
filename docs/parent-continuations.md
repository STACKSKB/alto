# Recovering a parent batch

Alto can optionally retain a parent continuation before a `spawn_agents` batch
dispatches any child. This boundary is shared by Serial and Stepped. It is
separate from an approval checkpoint and from the enclosing Consumer claim.

Configure the trusted parent with `continuation_store: parent_ledger`, a
`checkpoint_version`, and a durable `budget_account: account`. Its bounded
subagent policy must have a child `journal`. The parent loop must implement
`dump_checkpoint/2` and `load_checkpoint/2` for both its waiting-for-children
state and the state reached after receiving `subagents_completed`. All stores
must be supervised and private. The continuation ledger needs sufficient
`max_recovery_bytes` and `max_record_bytes` for the encoded frame; parent cell
packets are limited to 2 MB, with 64 KB metadata. Store limits can be lower.

The optional trusted `continuation_key` identifies the host's logical task in
cell metadata. It is not an execution grant. The resident Registry accepts it,
per-task `budget_account`, and a `continuation` identity through its Elixir API;
socket `start_run` commands cannot inject these options.

## Boundaries and grants

1. Validate the batch and prepare its resources and journal. The spawn effect
   has already consumed its budget reservation.
2. Save the pending loop state, exact conversation, remaining effects, terminal
   disposition, journal generation/child order, usage, authority limits and
   original execution expiry. No child starts if this write fails.
3. Execute the children normally. Each worker retains its own exact outcome.
4. Read the ordered retained results, merge usage and verdict once, and compute
   the parent transition. Save its exact ready frame before acknowledging the
   journal with the continuation identity and ready revision.
5. Claim the ready cell with a one-use compare-and-swap before the scheduler
   executes its next effect. A claimed cell never reissues that grant.

The reusable `Alto.Subagents.Continuation` cell supplies `open/5`, `identity/1`,
`restore/3`, `read/1`, `ready/3` and `claim/2`. Its pending, ready and claimed
states survive store restart. Generation and revision checks prevent replacement
or competing consumers from issuing a second grant. Claimed cells remain
retained; automatic retirement is not part of this contract.

## Explicit recovery

After establishing that the original execution has stopped, inspect the
continuation ledger with `Alto.OperationLog.keys/1` and `recovery/2`. Recover a
cell using its saved key and generation, and inspect it with
`Alto.Subagents.Continuation.read/1`. Hosts choose the matching logical task;
they must not select an unrelated generation or turn a missing cell into new
work.

Start a fresh run with the original trusted configuration and
`continuation: identity`. Alto resolves the saved session and restores the
parent without calling loop initialization, preparing workspaces, or
issuing new child dispatches. A pending cell restores its journal and resumes
only children with explicitly retained approval decisions before joining. All
children must have retained outcomes before the parent consumes its frame. A
ready cell already holds the exact consuming frame. Recovery never invents an
approval decision; see [independent child approvals](child-continuations.md).

An incomplete journal returns `{:error, {:children_pending, reason}, result}`.
The result's checkpoint identifies the parent cell. Other ungranted parent
errors also carry a parent checkpoint marker; their partial conversations are
not written over the stored transcript. A losing concurrent recovery cannot
overwrite the successful consumer's conversation. Hosts should retain the
parent for review rather than resubmit its original prompt.

Configuration, loop/tool code, store identity, journal generation, transcript
revision and budget account must match. Authority ceilings cannot be widened
by restore. The durable account includes charges made after capture, while
the original absolute expiry conservatively charges child execution and host
downtime. Clock correctness is therefore required; this is not coordinated
pausable active-time accounting for independent children.

## Limits

This path covers root `spawn_agents` batches, including a one-child batch.
It does not make standalone `spawn_agent` calls or recursive parent continuations
recoverable. A dispatched child without a saved result or approval checkpoint remains
uncertain. Joining may not invoke provider-backed transcript compaction before
a grant: an oversized result transcript fails instead. Custom loop checkpoint
and transition callbacks must remain pure.

A crash after the ready grant requires reconciliation; it does not authorize
replaying later model requests or integration effects. Ordinary tool approvals
may still suspend later integration using their existing checkpoint contract.
Journal acknowledgement records durable consumption, but journal retirement,
parent-cell retirement and budget-account closure remain explicit host lifecycle
work. Retention exhaustion fails closed.

## Qualification

On 2026-09-12, all 853 Alto tests pass at bounded concurrency, including the
new retained-cell, parent checkpoint, live/restarted runner, independent child
approval, cancellation, provider resolution and concurrent transcript preservation
tests. Production compilation with warnings as errors
and formatting pass. Downstream Zekkyou checks additionally recover through its
resident CLI across three independent service VMs with Serial and Stepped,
observing exactly one planner call, one child effect and one integration effect.
