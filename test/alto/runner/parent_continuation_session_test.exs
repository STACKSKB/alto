defmodule Alto.Runner.ParentContinuationSessionTest do
  use ExUnit.Case, async: true

  alias Alto.{Event, OperationLog, Session, Transition}
  alias Alto.Runner.{Checkpoint, Execution}
  alias Alto.Runner.Budget.Account
  alias Alto.Subagents.{Continuation, Journal}

  defmodule JoinLoop do
    @behaviour Alto.Loop
    def init(_task, _spec), do: Transition.continue(%{phase: :children})

    def handle_event(%Event{type: :subagents_completed}, state, spec) do
      send(Keyword.fetch!(spec.driver_options, :observer), {:joining, self()})

      receive do
        :continue -> Transition.stop(state, "joined once")
      end
    end

    def handle_event(_event, state, _spec), do: Transition.continue(state)
    def dump_checkpoint(state, _spec), do: {:ok, state}
    def load_checkpoint(state, _spec), do: {:ok, state}
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-parent-session-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    ledger =
      start_supervised!(
        {OperationLog,
         name: nil,
         id: "continuations",
         dir: dir,
         max_recovery_bytes: 2_200_000,
         max_record_bytes: 3_000_000}
      )

    {:ok, account} = Account.open(ledger, "budget", max_effects: 50, max_model_requests: 20)
    {:ok, session} = Session.create("task", %{}, session_dir: dir)

    opts = [
      loop:
        Alto.loop(JoinLoop,
          observer: self(),
          subagents:
            Alto.Subagents.bounded(
              max_depth: 1,
              max_children: 1,
              max_concurrency: 1,
              journal: ledger
            )
        ),
      tools: [],
      cwd: dir,
      session: session,
      session_dir: dir,
      resume_snapshot: true,
      checkpoint_version: "session-v1",
      continuation_store: ledger,
      budget_account: account,
      max_effects: 50,
      max_model_requests: 20,
      run_timeout: 10_000
    ]

    {:ok, run} = Execution.Setup.open("original task", opts)
    run = %{run | loop_state: %{phase: :children}}

    {:ok, journal} =
      Journal.open(ledger, "children", ["worker"], %{
        "agent_identity" => Alto.Protocol.encode_term(run.agent_identity)
      })

    {:ok, _} =
      Journal.skip(journal, "worker", %{id: "worker", status: :error, error: :not_started})

    pending = %{kind: :children, journal: Journal.identity(journal), ids: ["worker"]}
    {:ok, packet} = Checkpoint.capture_parent(run, pending, [], :continue)

    {:ok, cell} =
      Continuation.open(ledger, "parent", packet, %{"journal" => Journal.identity(journal)})

    opts = Keyword.put(opts, :continuation, Continuation.identity(cell))
    %{opts: opts, session: session, dir: dir, cell: cell}
  end

  test "a losing concurrent resume preserves the winner's completed transcript", context do
    %{opts: opts, session: session, dir: dir, cell: cell} = context
    first = Task.async(fn -> Alto.run(:ignored, opts) end)
    assert_receive {:joining, first_policy}, 2_000
    second = Task.async(fn -> Alto.run(:ignored, opts) end)
    assert_receive {:joining, second_policy}, 2_000

    send(first_policy, :continue)
    assert {:ok, winner} = Task.await(first, 5_000)
    assert winner.output == "joined once"
    assert {:ok, before} = Session.transcript(session, session_dir: dir)
    assert before.messages == winner.messages
    assert before.revision == 1
    assert {:ok, %{phase: :claimed}} = Continuation.read(cell)

    send(second_policy, :continue)
    assert {:error, _reason, loser} = Task.await(second, 5_000)
    assert loser.checkpoint["kind"] == "parent"
    assert Session.transcript(session, session_dir: dir) == {:ok, before}
    refute_receive {:joining, _}, 30
  end
end
