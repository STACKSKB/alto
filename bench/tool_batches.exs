defmodule Alto.Bench.OfflineBatchLoop do
  @behaviour Alto.Loop

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Transition

  @impl true
  def init(_task, spec) do
    count = Keyword.fetch!(spec.driver_options, :count)
    mode = Keyword.fetch!(spec.driver_options, :mode)

    calls =
      for index <- 1..count do
        %{
          id: "read-#{index}",
          name: "offline_read",
          arguments_json: JSON.encode!(%{"index" => index})
        }
      end

    effects =
      case mode do
        :serial -> Enum.map(calls, &Effect.run_tool/1)
        :parallel -> [Effect.run_tools(calls, 4)]
      end

    Transition.continue(%{count: count, values: []}, effects)
  end

  @impl true
  def handle_event(
        %Event{type: :tool_completed, data: %{call_id: call_id, value: value}},
        %{values: values, count: count} = state,
        _spec
      ) do
    values = [{call_id, value} | values]

    if length(values) == count,
      do: Transition.stop(%{state | values: values}, Enum.reverse(values)),
      else: Transition.continue(%{state | values: values})
  end

  def handle_event(%Event{type: :tool_failed, data: data}, _state, _spec),
    do: Transition.error(%{}, {:unexpected_tool_failure, data})

  def handle_event(%Event{}, state, _spec), do: Transition.continue(state)
end

defmodule Alto.Bench.OfflineReadTool do
  @behaviour Alto.Tool

  @impl true
  def name, do: :offline_read

  @impl true
  def schema, do: %{parameters: %{type: "object", properties: %{index: %{type: "integer"}}}}

  @impl true
  def execution_mode, do: :parallel

  @impl true
  def approval, do: :never

  @impl true
  def run(%{"index" => index}, _context, opts) do
    Agent.update(Keyword.fetch!(opts, :counter), &(&1 + 1))
    Process.sleep(Keyword.fetch!(opts, :delay_ms))
    {:ok, index}
  end
end

defmodule Alto.Bench.OfflineToolBatches do
  @calls 8
  @delay_ms 20
  @samples 3

  def run(mode) do
    Enum.map(1..@samples, fn sample ->
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      started = System.monotonic_time(:microsecond)

      result =
        Alto.run(%{"benchmark" => true},
          loop: Alto.Loop.Spec.new(Alto.Bench.OfflineBatchLoop, mode: mode, count: @calls),
          tools: [{Alto.Bench.OfflineReadTool, counter: counter, delay_ms: @delay_ms}],
          provider: nil,
          approval: Alto.Approvals.DenyAll,
          max_steps: 32
        )

      elapsed_us = System.monotonic_time(:microsecond) - started
      count = Agent.get(counter, & &1)
      Agent.stop(counter)

      {:ok, run_result} = result
      values = run_result.output

      unless count == @calls and length(values) == @calls do
        raise "benchmark run did not execute #{@calls} identical calls: #{inspect(result)}"
      end

      %{sample: sample, calls: count, elapsed_ms: Float.round(elapsed_us / 1_000, 2)}
    end)
  end

  def print(mode, samples) do
    elapsed = Enum.map(samples, & &1.elapsed_ms)
    average = Enum.sum(elapsed) / length(elapsed)

    IO.puts(
      "#{mode} calls=#{Enum.map_join(samples, ",", & &1.calls)} " <>
        "elapsed_ms=#{Enum.map_join(elapsed, ",", &Float.to_string/1)} " <>
        "average_ms=#{Float.round(average, 2)}"
    )
  end
end

IO.puts("offline read-only tool batch benchmark (8 calls, 20ms fake I/O each)")
serial = Alto.Bench.OfflineToolBatches.run(:serial)
parallel = Alto.Bench.OfflineToolBatches.run(:parallel)
Alto.Bench.OfflineToolBatches.print(:serial, serial)
Alto.Bench.OfflineToolBatches.print(:parallel, parallel)
