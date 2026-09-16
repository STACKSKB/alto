# Offline benchmark and provider comparison

The repository includes a deterministic scheduling benchmark at
[`bench/tool_batches.exs`](../bench/tool_batches.exs). It runs the same eight
approval-free, read-only fake calls with a 20 ms sleep in two modes: ordered
serial effects and one explicit parallel batch with a concurrency limit of four.
The fake tool increments a counter, so every sample checks that all eight calls
ran and all eight results were returned. No provider, network, model output, or
quality claim is involved.

Run it from the repository root:

```sh
mix run bench/tool_batches.exs
```

The output reports the per-sample call counts, elapsed milliseconds, and the
sample average. Elapsed time depends on the host scheduler and load; compare
serial and parallel runs from the same checkout and machine. The benchmark is
useful for checking the execution boundary and scheduling cost. It is not a
provider performance benchmark.

For an Alto versus Pi comparison, use the same provider model and request set
in both harnesses. Keep the prompt, tool fixtures, tool permissions, model
parameters, retry policy, context window, output reservation, and concurrency
settings identical. Start each case from a fresh session or the same retained
revision, and repeat each case enough times to report a median and spread.

Record these measurements separately:

- quality: a fixed rubric with success, required corrections, tool-call
  correctness, and reviewer-blinded task outcomes;
- latency: wall-clock duration, time to first model event, each provider request,
  and tool-batch duration from monotonic host timestamps;
- usage: provider-reported input and output tokens from `Result.usage`, model
  request count, and any cache fields;
- cost: token usage multiplied by the price card for the exact model and date,
  with currency and pricing assumptions recorded beside the result.

Do not infer provider token counts from Alto's conservative context estimator,
and do not convert elapsed time into quality or cost. Keep model quality,
provider usage, host scheduling, and tool behavior as separate columns in the
comparison record.
