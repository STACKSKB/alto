# Desloppification plan

Alto is still at `0.0.1`. Internal storage formats may change without migration,
but every current capability remains in scope, including features enabled only
through external configuration. The goal is less production code with clearer
data flow, not a smaller product.

## Measure the result

The starting inventory was 40,655 physical lines in production `.ex` files.
The 2026-09-24 inventory is 33,562 lines, a reduction of 7,093 (17.4%). A 30%
reduction would require at most 28,458 lines, or another 5,104 lines below the
current inventory. Test files are tracked separately and never count toward
that production target. Recount after each coherent change; a moved line is not
a reduction.

The largest remaining files are `Alto.TUI.App` (1,742),
`Alto.Runner.Execution` (1,329), `Alto.Queue` (1,089),
`Alto.FrontEnd.Registry` (1,009), `Alto.TUI.Backends.Codex` (919),
`Alto.TUI.View` (897), and `Alto.OperationLog` (855). Their size identifies
where to investigate, not what to delete. Focused audits found that many
apparently similar branches differ in authority, cancellation, event ordering,
or recovery guarantees; extracting a helper just to reduce line count can make
those rules harder to see.

## Next passes

1. **Runner state and effect flow.** Map every field of the run context to its
   owner and readers. Prototype a smaller typed context or a set of cohesive
   state records, then compare the entire runner module group before adopting
   it. Keep effect ordering, approval suspension, budget reservation, provider
   correlation, and child accounting explicit. Reject a design that merely
   relocates the existing 40-field map or adds adapter layers.
2. **Durable state machines.** Compare queue, operation ledger, session, and
   continuation code at the record/transition boundary. Consolidate only
   genuinely shared framing, validation, or atomic persistence. The approved
   native v2 formats need no v1 compatibility path, but corrupt or partially
   written current records must remain observable and safe. A transition
   should have one live and replay implementation.
3. **TUI state flow.** Keep catalog recovery, backend selection, approval,
   clipboard, and selection capabilities. Look for state that the app stores
   twice or re-derives on every event; move pure decisions to existing state or
   view modules only when the complete TUI group shrinks and event races remain
   testable. Do not collapse view geometry that also controls mouse hit tests
   or text selection.
4. **Other production surfaces.** Audit CLI, listeners, tools, and providers
   for duplicated domain policy. Prefer one validation or display boundary
   where callers really share a contract. Preserve externally configured
   Ripwire, FFF, webhook, and other adapters even if no default config uses them.
5. **Tests.** Remove tests that restate a constructor, the language, or a
   library operation, and duplicate scenarios superseded by a stronger
   integration test. Keep tests that establish Alto's behavior under malformed
   input, cancellation, concurrency, data corruption, or authority checks.
   Review the assertion and the behavior it protects, rather than deleting a
   test solely because it is short.

For each pass: state the invariant, make one cohesive edit, run focused tests
and both full suites when the change crosses a shared boundary, then compare
production and test line counts. If a proposed abstraction does not improve
readability and reduce net production code, revert it. The 30% figure is a
hypothesis to test, not a reason to erase useful safeguards or capabilities.
