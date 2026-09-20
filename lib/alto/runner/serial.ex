defmodule Alto.Runner.Serial do
  @moduledoc """
  Sequential effect execution with optional caller-controlled admission.

  Automatic mode executes effects immediately. With
  `runner_options: [mode: :manual, controller: pid]`, the controller receives
  `{:alto_step_ready, ticket, summary}` before each effect and calls `advance/1`.
  Tickets admit exactly one frame and cannot be reused. Waiting consumes the
  run deadline, remains cancellable, and does not bypass tool approval.
  """
  @behaviour Alto.Runner
  alias Alto.Runner.{Execution, Result, TaskHost}

  defmodule Ticket do
    @moduledoc "A one-use capability to admit the next frame."
    @enforce_keys [:pid, :ref]
    defstruct [:pid, :ref]
    @opaque t :: %__MODULE__{pid: pid(), ref: reference()}
  end

  @doc "Admit the effect identified by this ticket. Duplicate/stale grants are ignored."
  def advance(%Ticket{pid: pid, ref: ref}) do
    send(pid, {:alto_advance, ref})
    :ok
  end

  @impl true
  def run(task, opts \\ []) do
    case settings(Keyword.get(opts, :runner_options, [])) do
      {:ok, controller} ->
        monitor = if controller, do: Process.monitor(controller)

        try do
          Execution.run(
            task,
            Keyword.put_new(opts, :runner, __MODULE__),
            &schedule(&1, &2, controller, monitor)
          )
        after
          if monitor, do: Process.demonitor(monitor, [:flush])
        end

      {:error, reason} ->
        {:error, reason, Result.empty()}
    end
  end

  defp settings(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:mode, :controller] == [] do
      case {Keyword.get(opts, :mode, :automatic), Keyword.get(opts, :controller)} do
        {:automatic, nil} -> {:ok, nil}
        {:manual, pid} when is_pid(pid) -> {:ok, pid}
        _ -> {:error, :invalid_runner_options}
      end
    else
      {:error, :invalid_runner_options}
    end
  end

  defp settings(_), do: {:error, :invalid_runner_options}

  defp schedule(frame, context, nil, monitor),
    do: advance_frame(frame, context, nil, monitor)

  defp schedule(%Execution.Frame{effects: []} = frame, context, controller, monitor),
    do: advance_frame(frame, context, controller, monitor)

  defp schedule(frame, context, controller, monitor) do
    ref = make_ref()

    send(
      controller,
      {:alto_step_ready, %Ticket{pid: self(), ref: ref},
       %{pending_effects: length(frame.effects), next_effect: hd(frame.effects).kind}}
    )

    await_grant(ref, frame, context, controller, monitor)
  end

  defp await_grant(ref, frame, context, controller, monitor) do
    case Execution.check(context) do
      :ok ->
        receive do
          {:alto_advance, ^ref} ->
            advance_frame(frame, context, controller, monitor)

          {:alto_advance, _stale} ->
            await_grant(ref, frame, context, controller, monitor)

          {:DOWN, ^monitor, :process, _, reason} ->
            Execution.abort(context, {:cancelled, {:step_controller_down, reason}})
        after
          25 -> await_grant(ref, frame, context, controller, monitor)
        end

      {:error, reason} ->
        Execution.abort(context, reason)

      {:cancelled, reason} ->
        Execution.abort(context, {:cancelled, reason})
    end
  end

  defp advance_frame(frame, context, controller, monitor) do
    case Execution.step(frame, context) do
      {:continue, frame, context} -> schedule(frame, context, controller, monitor)
      {:done, outcome} -> outcome
    end
  end

  @impl true
  def start(task, opts \\ []) do
    TaskHost.start(fn ref -> run(task, Keyword.put(opts, :cancel_ref, ref)) end, opts)
  end

  @impl true
  defdelegate await(handle, timeout \\ :infinity), to: TaskHost
  @impl true
  defdelegate cancel(handle, reason \\ :user), to: TaskHost
  @impl true
  defdelegate terminate(handle, reason \\ :cancel_timeout), to: TaskHost
  @impl true
  defdelegate subscribe(handle, pid \\ self()), to: TaskHost
end
