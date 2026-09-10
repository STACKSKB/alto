defmodule Alto.Runner.Execution.Call do
  @moduledoc "Bounded, cancellable participant invocation used by runner hosts."

  defdelegate run(fun, timeout, cancel_ref),
    to: Alto.Runner.Execution.Support,
    as: :supervised_call

  defdelegate cancellation(cancel_ref), to: Alto.Runner.Execution.Support
end
