# Extension boundaries

Alto keeps application choices at explicit boundaries. A host can add hooks
around lifecycle events, configure trusted commands, transform model supplied
tool input, select an optional renderer or front end, and choose provider
adapters without changing the runner.

## Transforming tool input

`Alto.Tools.Transform` is a host-side input adapter. It wraps a normal tool
specification and applies a two argument function `(arguments, context)` once,
when the invocation is prepared. The transformed arguments are included in the
approval details and the resulting opaque value is passed unchanged through
approval to execution.

```elixir
path_transform = fn args, context ->
  {:ok, Map.put(args, "path", Path.expand(args["path"], context.cwd))}
end

tools = [
  Alto.Tools.Transform.wrap(Alto.Tools.ReadFile, path_transform)
]
```

The wrapped tool retains its name, schema, approval requirement, and execution
mode. Prepared tools keep their own `prepare` and `run_prepared` callbacks. A
run-only tool receives the transformed argument map through the wrapper's
preparation boundary. Keep transforms deterministic and local; authorization
should describe the value that will be executed.

## Context estimates

`Alto.Context.Window` accepts a unary estimator. `Alto.Context.Estimator` adapts
a tokenizer function and adds provider and model framing values:

```elixir
estimator =
  Alto.Context.Estimator.new(
    tokenizer: &MyTokenizer.count/1,
    provider_overhead: 16,
    message_overhead: 4,
    tool_overhead: 8,
    model: "claude-sonnet-4-5",
    model_overhead: %{"claude-sonnet-4-5" => 12}
  )

context = Alto.Context.window(
  max_tokens: 200_000,
  reserve_output: 16_000,
  estimator: estimator
)
```

The tokenizer receives the JSON representation of each message and tool
definition. Framing values account for provider and model request structure.
Neither the default byte tokenizer nor a custom tokenizer is an exact provider
count unless the host calibrates it against the selected model and request
shape. Provider usage remains authoritative after a request completes.

## Hooks, commands, and clients

Lifecycle hooks observe typed events and may record metrics or project state.
They do not replace approval or execution boundaries. Command tools should use
the configured command executor: sandboxed commands are appropriate for model
requested work, while unsandboxed commands belong to explicitly trusted host
workflows and should be configured with narrow permissions.

Renderers are optional front ends. The CLI, TUI, GUI, and protocol clients
consume the same events and approval handles; a host can provide another
renderer without changing tools or providers. Provider adapters are also
optional dependencies at the application boundary. A host can select a native
adapter or an OpenAI-compatible endpoint and keep credentials, retries, and
provider-specific setup outside the core execution contract.
