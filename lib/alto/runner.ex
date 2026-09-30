defmodule Alto.Runner do
  @moduledoc """
  Execution-host contract and runner selection.

  See `docs/runners.md` for runner selection and lifecycle examples.

  `subscribe/2` returns a reference. Exactly one
  `{:alto_runner_result, reference, outcome}` message follows, including when
  subscription occurs after completion. Await timeouts do not cancel runs.
  Hosts must honor `:owner` cancellation and the supplied execution bounds.
  Checkpoint support is a host capability: unsupported packets must fail closed.
  """

  alias Alto.Runner.Handle
  alias Alto.Runner.Result
  @type outcome :: Result.t()
  @callback run(term(), keyword()) :: outcome()
  @callback start(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback await(term(), timeout()) :: outcome() | {:error, :await_timeout}
  @callback cancel(term(), term()) :: :ok | :already_finished
  @callback terminate(term(), term()) :: outcome()
  @callback release(term()) :: :ok | {:error, term()}
  @optional_callbacks release: 1
  @callback subscribe(term(), pid()) :: {:ok, reference()} | {:error, term()}

  @doc "The default execution host."
  def default, do: Alto.Runner.Serial

  def run(task, opts \\ []) do
    module = Keyword.get(opts, :runner, default())
    module.run(task, opts)
  end

  def start(task, opts \\ []) do
    module = Keyword.get(opts, :runner, default())

    with {:ok, state} <- module.start(task, opts),
         do: {:ok, %Handle{runner: module, state: state}}
  end

  def await(%Handle{runner: runner, state: state}, timeout \\ :infinity),
    do: runner.await(state, timeout)

  def cancel(%Handle{runner: runner, state: state}, reason \\ :user),
    do: runner.cancel(state, reason)

  @doc "Stop after cooperative cancellation has failed; the outcome may be unknown."
  def terminate(%Handle{runner: runner, state: state}, reason \\ :cancel_timeout),
    do: runner.terminate(state, reason)

  @doc "Release a completed outcome after its owner has consumed it. Running work is untouched."
  def release(%Handle{runner: runner, state: state}) do
    if function_exported?(runner, :release, 1),
      do: runner.release(state),
      else: {:error, :unsupported}
  end

  def release(_), do: {:error, :unsupported}

  def subscribe(%Handle{runner: runner, state: state}, pid \\ self()),
    do: runner.subscribe(state, pid)
end
