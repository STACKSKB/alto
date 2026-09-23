defmodule Alto.Runner.CheckpointTest do
  use ExUnit.Case, async: false
  alias Alto.Runner.{Checkpoint, Serial}

  defmodule First do
    use Alto.Tool, name: :first, execution_mode: :exclusive, approval: :never
    def schema(_opts), do: %{description: "First", parameters: %{type: "object", properties: %{}}}

    def run(_, context, _opts) do
      File.write!(Path.join(context.cwd, "first"), "1", [:append])
      {:ok, "first"}
    end
  end

  defmodule Guarded do
    use Alto.Tool, name: :guarded, execution_mode: :exclusive, approval: :required

    def schema(_opts),
      do: %{description: "Guarded", parameters: %{type: "object", properties: %{}}}

    def prepare(_, context, _opts) do
      File.write!(Path.join(context.cwd, "preparations"), "1", [:append])
      value = File.read!(Path.join(context.cwd, "input"))
      {:ok, %{value: value}, %{value: value, prepared_by: self()}}
    end

    def run_prepared(prepared, context, _opts) do
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

  defmodule RaisingLoadLoop do
    @behaviour Alto.Loop
    def init(task, spec), do: Alto.Loops.Rule.init(task, spec)
    def handle_event(event, state, spec), do: Alto.Loops.Rule.handle_event(event, state, spec)
    def dump_checkpoint(state, spec), do: Alto.Loops.Rule.dump_checkpoint(state, spec)
    def load_checkpoint(_state, _spec), do: raise("checkpoint programmer error")
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
    assert %{"$inspect" => _} = suspended.checkpoint["request"]["details"]["prepared_by"]
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
    owner = self()

    opts =
      opts
      |> Keyword.put(:loop, Alto.default_loop())
      |> Keyword.put(:provider, {Provider, owner: self()})
      |> Keyword.put(:prompt, fn _context ->
        send(owner, :prompt_built)
        "Saved system prompt"
      end)

    assert {:error, :approval_suspended, suspended} = Serial.run("do the work", opts)
    assert_receive {:model_request, _}
    assert_receive :prompt_built
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
    assert hd(messages) == %{"role" => "system", "content" => "Saved system prompt"}
    refute_receive :prompt_built, 50
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

  test "changed configuration fails before dispatch", %{dir: dir, opts: opts} do
    {:error, :approval_suspended, result} = Serial.run("{}", opts)

    changed =
      opts
      |> Keyword.put(:loop, Alto.rule_loop(steps: ["guarded"]))
      |> Keyword.put(:checkpoint, {result.checkpoint, :approve})

    assert {:error, :checkpoint_mismatch, _} = Serial.run("{}", changed)
    refute File.exists?(Path.join(dir, "guarded"))

    obsolete = Map.put(result.checkpoint, "continuation_format", 1)

    assert {:error, :invalid_checkpoint, _} =
             Serial.run("{}", Keyword.put(opts, :checkpoint, {obsolete, :approve}))

    refute File.exists?(Path.join(dir, "guarded"))
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

  test "a programmer error in checkpoint restore is not relabeled invalid_checkpoint", %{
    opts: opts
  } do
    opts = Keyword.put(opts, :loop, Alto.loop(RaisingLoadLoop, steps: ["guarded"]))
    assert {:error, :approval_suspended, suspended} = Serial.run("{}", opts)
    assert {:ok, run} = Alto.Runner.Execution.Setup.open("{}", opts)

    assert_raise RuntimeError, "checkpoint programmer error", fn ->
      Checkpoint.restore(run, suspended.checkpoint, :approve, opts)
    end
  end

  test "checkpoint fingerprints remain deterministic for large tool option maps", %{
    opts: opts
  } do
    tool_options = Map.new(1..40, &{"key-#{&1}", &1})
    equivalent_options = tool_options |> Map.to_list() |> Enum.reverse() |> Map.new()

    opts = Keyword.put(opts, :tools, [{First, options: tool_options}, Guarded])
    assert {:error, :approval_suspended, suspended} = Serial.run("{}", opts)

    equivalent = Keyword.put(opts, :tools, [{First, options: equivalent_options}, Guarded])

    assert {:ok, _resumed} =
             Serial.run(
               "{}",
               Keyword.put(equivalent, :checkpoint, {suspended.checkpoint, :approve})
             )

    changed_options = Map.put(tool_options, "key-40", :changed)
    changed = Keyword.put(opts, :tools, [{First, options: changed_options}, Guarded])

    assert {:error, :checkpoint_mismatch, _} =
             Serial.run("{}", Keyword.put(changed, :checkpoint, {suspended.checkpoint, :approve}))
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
end
