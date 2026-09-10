# Approval continuations

`Alto.Approvals.Checkpoint` returns `:suspend` at a required tool approval.
With an explicit `checkpoint_version` and a loop implementing the optional
checkpoint callbacks, the shared execution hosts return:

```elixir
{:error, :approval_suspended, %Alto.Runner.Result{checkpoint: packet}}
```

The prepared tool has not executed. The packet contains the exact pending
prepared value, remaining ordered effects, declared loop state, transcript,
operation identity, accounting, and remaining execution budget. Completed
operations are not replayed and tool preparation is not repeated. Root serial
runs are supported; child runs cannot independently suspend a shared parent.

The runner does not persist or authorize its own continuation. A durable host
uses the existing operation ledger and queue:

1. Record intent and the current dispatch attempt before running.
2. `record_checkpoint(ledger, key, attempt, packet)` persists the checkpoint.
3. Acknowledge the queue claim only after that write succeeds. `Alto.Consumer`
   implements this ordering for a `{:checkpoint, packet}` handler return.
4. Display the approval and current ledger revision. Record a host decision with
   `resume_checkpoint(ledger, key, revision, decision_map)` before readmission.
5. Restore a queue delivery using `Queue.restore/5` and the returned revision as
   `recovery_revision`. The next attempt must be written before continuation.
6. Run with trusted options `checkpoint: {packet, :approve | :deny}`. The trusted
   registry API accepts the same option; socket `start_run` never accepts it.

A checkpointed claim is acknowledged without executing the handler again.
Healthy checkpoint segments do not consume the consumer's ordinary retry
allowance; their distinct dispatch identities remain in the bounded ledger.
`checkpoint_grant_revision` identifies the grant. The immediately following
attempt has revision `grant + 1`; hosts must not reuse an old checkpoint
approval following a later uncertain dispatch. Queue-full admission and crashes
between the grant and queue restoration remain host recovery responsibilities.
The Zekkyou task host implements these policies.

`resume_checkpoint` accepts an opaque bounded JSON decision map. It is a generic
host decision boundary, not a tool permission policy. First decision wins by
revision. Checkpointed operations cannot accept another attempt, outcome or
release until explicitly resumed. Their records are not evicted as completed
work. Truncated trailing log records are repaired using Alto's existing durable
log contract; malformed interior records fail closed.

## Portability and bounds

The shipped Default, Chat and Rule loops implement `dump_checkpoint/2` and
`load_checkpoint/2`. Custom loops must declare equivalent reconstruction;
Alto never calls `init` as a substitute for missing continuation state. Trusted
rule argument functions are rehydrated from configuration. Loop and tool code
and relevant execution configuration fingerprints must match. The explicit
version is another application-controlled compatibility fence.

Packets exclude provider configuration and live process capabilities. Exact
messages and prepared tool values may contain sensitive data and require
private storage. Pids, references, ports and functions in continuation data are
rejected. The exact state is at most 1 MB with depth at most 64; its Base64 wire
representation is larger. Decoding never creates atoms or loads client-selected
modules. Fresh-VM restoration requires any atoms in custom data to already be
provided by trusted loaded code. Unknown shapes fail closed.

Loop snapshot callbacks run under the runner's existing timeout and cancellation
supervision. Saved effect/model counters are preserved, and current stricter
limits further constrain restoration. Time spent waiting for a decision is
excluded from the remaining active execution time. Prepared tools retain their
own validation: a file changed during suspension may invalidate an approved
write. A rejected checkpoint restore does not replace a saved transcript.

The ledger applies `max_recovery_bytes`, `max_record_bytes` and `max_log_bytes`
to exact checkpoint packets; these bounds may need to exceed the small defaults
used by short queue examples. Checkpoints do not make an uncertain external
effect automatically retryable. Interruptions after resumed dispatch still
require authoritative reconciliation or explicit operator review.

Checkpoint packets include a versioned shared continuation format. Serial and
Stepped use that same format. Journal and workspace bindings use the durable
store identity, not the current server PID; restarting the same store preserves
the binding. Unavailable or different stores fail closed. Tool/loop code and
explicit checkpoint version checks still apply.

Packets captured before the runner refactor are deliberately rejected rather
than guessed into the new format. Reconcile any suspended operations before
upgrading; completed session transcripts remain resumable. See [runner migration](runners.md).
