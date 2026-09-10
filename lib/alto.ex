defmodule Alto do
  @moduledoc """
  Public constructors for Alto loop specifications.

  Alto owns execution mechanics. A loop specification selects or replaces the
  control policy and composes middleware around typed lifecycle events.
  """

  alias Alto.Loop.Spec
  alias Alto.Loops.Chat
  alias Alto.Loops.Default
  alias Alto.Loops.Rule
  alias Alto.Runner.Serial

  @doc "Build the shipped default loop as an ordinary, composable value."
  @spec default_loop(keyword()) :: Spec.t()
  def default_loop(opts \\ []) do
    opts
    |> Keyword.put_new(:context, Alto.Context.window())
    |> Keyword.put_new(:subagents, Alto.Subagents.bounded())
    |> then(&Spec.new(Default, &1))
  end

  @doc "Build the tool-free, one-request conversational loop."
  @spec chat_loop(keyword()) :: Spec.t()
  def chat_loop(opts \\ []) do
    opts
    |> Keyword.put_new(:context, Alto.Context.window())
    |> then(&Spec.new(Chat, &1))
  end

  @doc "Build a loop specification around a user-supplied loop module."
  @spec loop(module(), keyword()) :: Spec.t()
  def loop(driver, opts \\ []) when is_atom(driver), do: Spec.new(driver, opts)

  @doc """
  Build a provider-less scripted rule loop (see `Alto.Loops.Rule`).

  `:steps` is the script — tool names or `%{tool: ..., arguments: ...}`
  entries; the task carries the run's payload. Anything that is not a step
  script fails closed at run construction.
  """
  @spec rule_loop(keyword()) :: Spec.t()
  def rule_loop(opts \\ []), do: Spec.new(Rule, opts)

  @doc "Run a task with the sequential effect host."
  @spec run(term(), keyword()) :: Serial.run_result()
  def run(task, opts \\ []), do: Serial.run(task, opts)

  @doc """
  Continue a persisted session with a follow-up task.

  The session's latest transcript snapshot seeds the new run's history and
  the follow-up arrives as a fresh user message; provider, tools, approval,
  and bounds come from `opts` exactly like a new run, so credentials are
  re-resolved by the caller and never read from disk. Prompt options are
  ignored: resumed history carries its own system message.

  Returns a `Serial.run_result()` when a run starts, or a bare
  `{:error, reason}` when the session cannot be loaded — most notably
  `:no_resumable_transcript` for sessions whose runs never completed (the
  crash boundary: Alto records what happened, it does not invent history).
  """
  @spec resume(String.t(), term(), keyword()) :: Serial.run_result() | {:error, term()}
  def resume(session_id, task, opts \\ []) do
    dir_opts = Keyword.take(opts, [:session_dir])

    case Alto.Session.transcript(session_id, dir_opts) do
      {:ok, %{messages: messages, transcript_bytes: bytes, revision: revision}} ->
        opts
        |> Keyword.put(:session, session_id)
        |> Keyword.put(:resume, %{
          messages: messages,
          transcript_bytes: bytes,
          revision: revision
        })
        |> then(&Serial.run(task, &1))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Start a cancellable serial run without waiting for it."
  @spec start(term(), keyword()) :: {:ok, Serial.Handle.t()} | {:error, term()}
  def start(task, opts \\ []), do: Serial.start(task, opts)

  @doc "Wait for a cancellable run to finish."
  @spec await(Serial.Handle.t(), timeout()) :: Serial.run_result() | {:error, :await_timeout}
  def await(handle, timeout \\ :infinity), do: Serial.await(handle, timeout)

  @doc "Ask a running serial host to cancel its current work."
  @spec cancel(Serial.Handle.t(), term()) :: :ok | :already_finished
  def cancel(handle, reason \\ :user), do: Serial.cancel(handle, reason)
end
