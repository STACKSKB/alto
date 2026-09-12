# Independent child approvals

A root parent configured with a continuation store, a child journal, a durable
budget account and a checkpoint version can park while individual children wait
for approval. Serial and Stepped use the same boundaries. Child loops must
implement the loop checkpoint callbacks; the original normalized child spawn
profile must be portable. Inherited providers remain trusted host configuration.
For an explicit worker provider override, include a bounded `profile_key` in the
spawn request and implement the pure optional parent loop callback
`resolve_child_provider(profile_key, parent_spec)`. It returns `{:ok, provider}`
(or `{:ok, nil}` to inherit). The initial override must match that callback's
resolution. Only the profile key is retained; provider options and credentials
are excluded from the child profile and resolved again from the current trusted
parent during recovery. Unnamed explicit overrides cannot independently suspend.

The child saves its exact approval checkpoint in its journal before returning.
The packet includes the prepared tool arguments, loop state and pending effects,
conversation and transcript revision, original child profile, authority ceilings,
agent depth and identity, session ownership, budget account and original absolute
expiry. A child workspace remains worked while suspended; recovery reuses its
existing revision without another snapshot or checkout.

Inspect the parent cell's `metadata["journal"]`, restore that journal with
`Alto.Subagents.Journal.restore/3`, then use `read/1` and `suspended/1`. The latter
returns ordered entries with `id`, `state`, `identity`, `checkpoint`, `decision`
and `workspace` keys. The checkpoint's string-key `"request"` is the reviewable
approval request. Inspection does not decode the child loop state or run a
callback. Parent and journal stores are private and bounded; journal records
must have space for all retained child packets. Each child suspension is bounded
to 2 MB before encoding, and configured store limits can be smaller.

`Journal.decide(batch, viewed_revision, entry.identity, :approve | :deny)`
persists an explicit decision with a compare-and-swap. The identity binds the
journal generation, child id, original dispatch attempt and suspension nonce.
A sibling update invalidates a stale viewed revision. A new approval in the same
child gets a new nonce. Recording a decision never executes the tool.

After stopping the old parent, start the original trusted parent configuration
with `continuation: parent_identity`. Recovery validates and restores the saved
parent, then resumes only decided children. It derives each child's capabilities
from the retained spawn profile and current parent configuration, validates the
child checkpoint, and consumes its decision once immediately before the pending
tool operation. Approval runs the exact prepared value; denial supplies the
ordinary approval-denied event. Neither route initializes the loop, prepares the
tool again, starts a new child dispatch, or repeats completed siblings.

The journal retains each resumed result before the worker returns. The parent
joins only after every child has completed. Otherwise it returns
`{:error, {:children_pending, reason}, result}` with the same parent continuation
identity. Independently suspended siblings and decisions survive store restart.
Shared child sessions never replace the parent's transcript; separate child
sessions retain their own transcript ownership. Child usage is merged once at
parent join, while all reservations charge the shared durable account immediately.
Saved authority ceilings cannot increase, and host downtime consumes the original
absolute expiry.

A crash after consuming a decision leaves that child `"resuming"`, which is
uncertain work. Recovery parks it; it cannot approve it again or repeat dispatch.
A missing or invalid checkpoint likewise grants no execution. Child checkpoint
validation finishes before entering a retained workspace. The workspace then
checks its exact revision and admits the child's decision under its lock, before
activating use. Rejected validation or admission leaves the worked workspace
unchanged for a later valid attempt. A failure after admission remains uncertain
and requires reconciliation. Custom hosts can compose this boundary through
`Alto.Workspaces.resume/5`, supplying separate admission and execution callbacks.
Standalone `spawn_agent` recovery and recursive parent continuations are outside this path.
Custom loop checkpoint and transition callbacks must be pure. Lifecycle retirement
remains explicit host work after every child is joined and the parent is settled.
