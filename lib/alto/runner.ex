defmodule Alto.Runner do
  @moduledoc """
  Execution-host contract and runner selection.

  Set `runner: MyRunner` in run options or an `Alto.Config`. Serial is the
  default. Hosts own their private handles; callers use this module to await,
  cancel, terminate, or subscribe without assuming a process or Task layout.

  `subscribe/2` returns a reference. Exactly one
  `{:alto_runner_result, reference, outcome}` message follows, including when
  subscription occurs after completion. Await timeouts do not cancel runs.
  Hosts must honor `:owner` cancellation and the supplied execution bounds.
  Checkpoint support is a host capability: unsupported packets must fail closed.
  """

  alias Alto.Runner.{Handle, Result}
  @type outcome :: {:ok, Result.t()} | {:error, term(), Result.t()}
  @callback run(term(), keyword()) :: outcome()
  @callback start(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback await(term(), timeout()) :: outcome() | {:error, :await_timeout}
  @callback cancel(term(), term()) :: :ok | :already_finished
  @callback terminate(term(), term()) :: outcome()
  @callback subscribe(term(), pid()) :: {:ok, reference()} | {:error, term()}

  @callbacks [run: 2, start: 2, await: 2, cancel: 2, terminate: 2, subscribe: 2]

  @doc "The default execution host."
  def default, do: Alto.Runner.Serial

  def run(task, opts \\ []) do
    with {:ok, module} <- resolve(opts), do: module.run(task, opts)
  end

  def start(task, opts \\ []) do
    with {:ok, module} <- resolve(opts),
         {:ok, state} <- module.start(task, opts),
         do: {:ok, %Handle{runner: module, state: state}}
  end

  def await(%Handle{runner: runner, state: state}, timeout \\ :infinity),
    do: runner.await(state, timeout)

  def cancel(%Handle{runner: runner, state: state}, reason \\ :user),
    do: runner.cancel(state, reason)

  @doc "Stop after cooperative cancellation has failed; the outcome may be unknown."
  def terminate(%Handle{runner: runner, state: state}, reason \\ :cancel_timeout),
    do: runner.terminate(state, reason)

  def subscribe(%Handle{runner: runner, state: state}, pid \\ self()),
    do: runner.subscribe(state, pid)

  defp resolve(opts) do
    module = Keyword.get(opts, :runner, Alto.Runner.Serial)

    if is_atom(module) and Code.ensure_loaded?(module) and
         Enum.all?(@callbacks, fn {name, arity} -> function_exported?(module, name, arity) end),
       do: {:ok, module},
       else: {:error, {:invalid_runner, module}}
  end
end
