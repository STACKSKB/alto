defmodule Alto.Runner.CheckpointTest do
  use ExUnit.Case, async: false
  alias Alto.OperationLog
  alias Alto.Runner.{Checkpoint, Serial}

  defmodule First do
    @behaviour Alto.Tool
    def name, do: :first
    def schema, do: %{description: "First", parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :exclusive
    def approval, do: :never

    def run(_, context) do
      File.write!(Path.join(context.cwd, "first"), "1", [:append])
      {:ok, "first"}
    end
  end

  defmodule Guarded do
    @behaviour Alto.Tool
    def name, do: :guarded
    def schema, do: %{description: "Guarded", parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :exclusive
    def approval, do: :required

    def prepare(_, context) do
      File.write!(Path.join(context.cwd, "preparations"), "1", [:append])
      value = File.read!(Path.join(context.cwd, "input"))
      {:ok, %{value: value}, %{value: value}}
    end

    def run_prepared(prepared, context) do
      File.write!(Path.join(context.cwd, "guarded"), prepared.value, [:append])
      {:ok, prepared.value}
    end
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:owner], {:model_request, request.messages})

      if List.last(request.messages)["role"] == "user" do
        {:ok,
         %{
           message: "working",
           tool_calls: [
             %{id: "first-call", name: "first", arguments_json: "{}"},
             %{id: "guarded-call", name: "guarded", arguments_json: "{}"}
           ],
           usage: %{input_tokens: 3, output_tokens: 2}
         }}
      else
        {:ok, %{message: "done", tool_calls: [], usage: %{input_tokens: 5, output_tokens: 1}}}
      end
    end
  end

  defmodule HangingLoop do
    @behaviour Alto.Loop
    def init(task, spec), do: Alto.Loops.Rule.init(task, spec)
    def handle_event(event, state, spec), do: Alto.Loops.Rule.handle_event(event, state, spec)

    def dump_checkpoint(_state, _spec) do
      receive do
        :never -> {:error, :unreachable}
      end
    end

    def load_checkpoint(state, _spec), do: {:ok, state}
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto-checkpoint-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "input"), "original")
    on_exit(fn -> File.rm_rf!(dir) end)

    opts = [
      cwd: dir,
      provider: nil,
      loop: Alto.rule_loop(steps: ["first", "guarded"]),
      tools: [First, Guarded],
      approval: Alto.Approvals.Checkpoint,
      checkpoint_version: "test-1"
    ]

    %{dir: dir, opts: opts}
  end

  test "resume executes the exact prepared value without repeating an earlier effect", %{
    dir: dir,
    opts: opts
  } do
    assert {:error, :approval_suspended, suspended} = Serial.run("{}", opts)
    assert suspended.checkpoint["request"]["tool"] == "guarded"
    assert File.read!(Path.join(dir, "first")) == "1"
    refute File.exists?(Path.join(dir, "guarded"))
    packet = suspended.checkpoint |> JSON.encode!() |> JSON.decode!()
    File.write!(Path.join(dir, "input"), "changed after preparation")
    assert {:ok, result} = Serial.run("{}", Keyword.put(opts, :checkpoint, {packet, :approve}))
    assert result.output == ["first", "original"]
    assert result.verdict == :completed
    assert File.read!(Path.join(dir, "guarded")) == "original"
    assert File.read!(Path.join(dir, "first")) == "1"
    assert File.read!(Path.join(dir, "preparations")) == "1"
  end

  test "model tool batches resume pending calls without requesting the model again", %{
    dir: dir,
    opts: opts
  } do
    opts =
      opts
      |> Keyword.put(:loop, Alto.default_loop())
      |> Keyword.put(:provider, {Provider, owner: self()})

    assert {:error, :approval_suspended, suspended} = Serial.run("do the work", opts)
    assert_receive {:model_request, _}
    assert suspended.checkpoint["request"]["call_id"] == "guarded-call"

    assert {:ok, completed} =
             Serial.run(
               "do the work",
               Keyword.put(opts, :checkpoint, {suspended.checkpoint, :approve})
             )

    assert completed.output == "done"
    assert completed.model_requests == 2
    assert completed.usage.total_tokens == 11
    assert_receive {:model_request, messages}
    assert Enum.count(messages, &(&1["role"] == "tool")) == 2
    assert File.read!(Path.join(dir, "first")) == "1"
    refute_receive {:model_request, _}, 50
  end

  test "denial resumes the loop with a denied tool outcome and never dispatches", %{
    dir: dir,
    opts: opts
  } do
    {:error, :approval_suspended, result} = Serial.run("{}", opts)

    assert {:error, {:rule_step_failed, 2, "guarded", _}, _} =
             Serial.run("{}", Keyword.put(opts, :checkpoint, {result.checkpoint, :deny}))

    refute File.exists?(Path.join(dir, "guarded"))
    assert File.read!(Path.join(dir, "first")) == "1"
  end

  test "changed configuration and nonportable data fail before dispatch", %{dir: dir, opts: opts} do
    {:error, :approval_suspended, result} = Serial.run("{}", opts)

    changed =
      opts
      |> Keyword.put(:loop, Alto.rule_loop(steps: ["guarded"]))
      |> Keyword.put(:checkpoint, {result.checkpoint, :approve})

    assert {:error, :checkpoint_mismatch, _} = Serial.run("{}", changed)
    refute File.exists?(Path.join(dir, "guarded"))

    for value <- [self(), make_ref(), fn -> :ok end] do
      assert {:error, _} = Checkpoint.encode(%{value: value})
    end

    assert {:error, _} = Checkpoint.decode(Base.encode64(:erlang.term_to_binary(self())))
  end

  test "a stuck custom checkpoint callback is bounded and never dispatches the tool", %{
    opts: opts,
    dir: dir
  } do
    opts =
      opts
      |> Keyword.put(:loop, Alto.loop(HangingLoop, steps: ["guarded"]))
      |> Keyword.put(:run_timeout, 100)

    assert {:error, {:checkpoint_process_failed, :timeout}, _} = Serial.run("{}", opts)
    refute File.exists?(Path.join(dir, "guarded"))
  end

  test "a later suspension preserves the consumed effect budget", %{opts: opts, dir: dir} do
    opts =
      Keyword.put(opts, :loop, Alto.rule_loop(steps: ["guarded", "guarded", "first"]))
      |> Keyword.put(:max_effects, 2)

    {:error, :approval_suspended, first} = Serial.run("{}", opts)

    {:error, :approval_suspended, second} =
      Serial.run("{}", Keyword.put(opts, :checkpoint, {first.checkpoint, :approve}))

    assert second.checkpoint["budget"]["effects_used"] == 2

    assert {:error, {:effect_limit, 2}, _} =
             Serial.run("{}", Keyword.put(opts, :checkpoint, {second.checkpoint, :approve}))

    assert File.read!(Path.join(dir, "guarded")) == "originaloriginal"
    refute File.exists?(Path.join(dir, "first"))
  end

  test "checkpoint resumes after the configured journal store is restarted", %{
    opts: opts,
    dir: dir
  } do
    ledger_dir = Path.join(dir, "journal")
    ledger_opts = [id: "checkpoint-journal", name: nil, dir: ledger_dir]
    ledger = start_supervised!({OperationLog, ledger_opts}, id: :checkpoint_journal)

    with_journal = fn store ->
      Keyword.put(
        opts,
        :loop,
        Alto.rule_loop(
          steps: ["guarded"],
          subagents: Alto.Subagents.bounded(journal: store)
        )
      )
    end

    assert {:error, :approval_suspended, suspended} = Serial.run("{}", with_journal.(ledger))
    stop_supervised!(:checkpoint_journal)
    restarted = start_supervised!({OperationLog, ledger_opts}, id: :checkpoint_journal)

    assert {:ok, result} =
             Serial.run(
               "{}",
               Keyword.put(
                 with_journal.(restarted),
                 :checkpoint,
                 {suspended.checkpoint, :approve}
               )
             )

    assert result.verdict == :completed
  end

  test "checkpoint rejects a different configured journal store", %{opts: opts, dir: dir} do
    first_dir = Path.join(dir, "first-journal")
    second_dir = Path.join(dir, "second-journal")
    first_opts = [id: "checkpoint-journal", name: nil, dir: first_dir]
    second_opts = [id: "checkpoint-journal", name: nil, dir: second_dir]
    first = start_supervised!({OperationLog, first_opts}, id: :checkpoint_journal_first)
    second = start_supervised!({OperationLog, second_opts}, id: :checkpoint_journal_second)

    with_journal = fn store ->
      Keyword.put(
        opts,
        :loop,
        Alto.rule_loop(
          steps: ["guarded"],
          subagents: Alto.Subagents.bounded(journal: store)
        )
      )
    end

    assert {:error, :approval_suspended, suspended} = Serial.run("{}", with_journal.(first))

    assert {:error, :checkpoint_mismatch, _} =
             Serial.run(
               "{}",
               Keyword.put(with_journal.(second), :checkpoint, {suspended.checkpoint, :approve})
             )
  end
end
