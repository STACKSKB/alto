defmodule Alto.Runner.ContextPressureFaultTest do
  use ExUnit.Case, async: true

  defmodule Provider do
    @behaviour Alto.Provider

    def describe(opts), do: %{context_window: Keyword.fetch!(opts, :window)}

    def stream(request, _sink, opts) do
      send(Keyword.fetch!(opts, :owner), {:provider_request, request.messages})
      {:ok, %{message: "done", tool_calls: []}}
    end
  end

  defmodule FailingReducer do
    @behaviour Alto.Context.Compaction

    def reduce(_input, _limit, opts) do
      send(Keyword.fetch!(opts, :owner), :reduction_attempted)
      {:error, :cannot_reduce}
    end
  end

  defmodule SequenceReducer do
    @behaviour Alto.Context.Compaction

    def reduce(_input, _limit, opts) do
      output =
        Agent.get_and_update(Keyword.fetch!(opts, :outputs), fn [next | rest] ->
          {next, rest}
        end)

      send(Keyword.fetch!(opts, :owner), {:reduced_to, byte_size(output)})
      {:ok, output}
    end
  end

  defmodule BlockingReducer do
    @behaviour Alto.Context.Compaction

    def reduce(_input, _limit, opts) do
      send(Keyword.fetch!(opts, :owner), {:reducer_started, self()})

      receive do
        :never -> {:ok, "unused"}
      end
    end
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "alto-pressure-fault-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    messages = [
      %{"role" => "system", "content" => "system"},
      %{"role" => "user", "content" => String.duplicate("h", 600)},
      %{"role" => "assistant", "content" => "old answer"}
    ]

    base = [
      session: :new,
      session_dir: directory,
      resume: %{messages: messages, transcript_bytes: Alto.Context.Transcript.bytes(messages)},
      loop:
        Alto.default_loop(
          context:
            Alto.Context.window(
              compact_at: 0.4,
              estimator: fn %{messages: messages} ->
                Enum.reduce(messages, 0, fn message, bytes ->
                  bytes + byte_size(Map.get(message, "content") || "")
                end)
              end
            )
        ),
      provider: {Provider, owner: self(), window: 1_000}
    ]

    %{base: base}
  end

  test "soft pressure attempts a failed reducer once and still dispatches", %{base: base} do
    opts =
      Keyword.put(base, :compaction,
        strategy: {FailingReducer, owner: self()},
        keep_recent_messages: 1,
        max_compactions: 3
      )

    assert {:ok, result} = Alto.run("current", opts)
    assert_receive :reduction_attempted
    refute_receive :reduction_attempted, 20
    assert_receive {:provider_request, _}
    assert Enum.count(result.events, &(&1.type == :context_compact_failed)) == 1
    assert result.model_requests == 1
  end

  test "hard pressure preserves the original limit after one reducer failure", %{base: base} do
    opts =
      base
      |> Keyword.put(:provider, {Provider, owner: self(), window: 300})
      |> Keyword.put(:compaction,
        strategy: {FailingReducer, owner: self()},
        keep_recent_messages: 1,
        max_compactions: 3
      )

    assert {:error, {:context_limit, _}, result} = Alto.run("current", opts)
    assert_receive :reduction_attempted
    refute_receive :reduction_attempted, 20
    refute_receive {:provider_request, _}, 20
    assert Enum.count(result.events, &(&1.type == :context_compact_failed)) == 1
    assert result.model_requests == 0
  end

  test "successful soft reductions recheck pressure and stop within the allowance", %{base: base} do
    {:ok, outputs} = start_supervised({Agent, fn -> [String.duplicate("s", 500), "small"] end})

    opts =
      Keyword.put(base, :compaction,
        strategy: {SequenceReducer, owner: self(), outputs: outputs},
        keep_recent_messages: 1,
        max_compactions: 2
      )

    assert {:ok, result} = Alto.run("current", opts)
    assert_receive {:reduced_to, 500}
    assert_receive {:reduced_to, 5}
    refute_receive {:reduced_to, _}, 20
    assert_receive {:provider_request, messages}
    assert Enum.any?(messages, &String.ends_with?(&1["content"] || "", "small"))
    assert Enum.count(result.events, &(&1.type == :context_compacted)) == 2
    assert result.model_requests == 1
  end

  test "cancellation stops a reducer and never dispatches the oversized request", %{base: base} do
    opts =
      base
      |> Keyword.put(:provider, {Provider, owner: self(), window: 300})
      |> Keyword.put(:compaction,
        strategy: {BlockingReducer, owner: self()},
        keep_recent_messages: 1,
        max_compactions: 2
      )

    {:ok, handle} = Alto.start("current", opts)
    assert_receive {:reducer_started, reducer}
    reducer_ref = Process.monitor(reducer)
    assert :ok = Alto.cancel(handle, :operator_stop)
    assert {:error, {:cancelled, :operator_stop}, result} = Alto.await(handle)
    assert_receive {:DOWN, ^reducer_ref, :process, ^reducer, _}
    refute_receive {:provider_request, _}, 20
    assert result.model_requests == 0
  end
end
