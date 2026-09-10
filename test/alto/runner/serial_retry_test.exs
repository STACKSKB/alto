defmodule Alto.Runner.SerialRetryTest do
  @moduledoc """
  Bounded, visible retry for model transport only: transient network and
  retriable HTTP failures are retried with backoff and live events; provider
  deadlines, client errors, and every tool effect are never retried.
  """

  use ExUnit.Case, async: true

  alias Alto.Event

  defmodule ScriptedProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, opts) do
      agent = Keyword.fetch!(opts, :agent)
      attempt = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
      send(Keyword.fetch!(opts, :test_pid), {:attempt, attempt})
      Keyword.fetch!(opts, :script).(attempt)
    end
  end

  defmodule SleepyProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, _opts) do
      Process.sleep(30_000)
      {:ok, %{message: "too late", tool_calls: []}}
    end
  end

  defmodule BoomTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :boom

    @impl true
    def schema do
      %{description: "Always fails.", parameters: %{type: "object", properties: %{}}}
    end

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :never

    @impl true
    def run(_arguments, _context), do: {:error, :boom}
  end

  defmodule ToolThenAnswerProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), :provider_called)

      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        {:ok, %{message: "recovered", tool_calls: []}}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [%{id: "c1", name: "boom", arguments_json: "{}"}]
         }}
      end
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    %{agent: agent}
  end

  test "transport failures retry with visible events, then recover", %{agent: agent} do
    script = fn
      n when n < 2 -> {:error, {:transport_error, :econnrefused}}
      _n -> {:ok, %{message: "recovered", tool_calls: []}}
    end

    assert {:ok, result} =
             Alto.run("retry me",
               provider: {ScriptedProvider, test_pid: self(), agent: agent, script: script},
               tools: [],
               provider_retries: 3,
               event_sink: fn event -> send(self(), {:evt, event}) end
             )

    assert result.output == "recovered"
    assert result.model_requests == 1
    assert attempts(agent) == 3
    assert retry_events() == [{1, 4, :transport}, {2, 4, :transport}]
  end

  test "rate limits and server errors retry; client errors do not", %{agent: agent} do
    for {status, retried?} <- [{429, true}, {500, true}, {503, true}, {400, false}, {401, false}] do
      Agent.update(agent, fn _ -> 0 end)

      script = fn
        0 -> {:error, {:http_error, status, %{"message" => "x"}}}
        _n -> {:ok, %{message: "recovered", tool_calls: []}}
      end

      outcome =
        Alto.run("retry me",
          provider: {ScriptedProvider, test_pid: self(), agent: agent, script: script},
          tools: [],
          provider_retries: 2,
          event_sink: fn event -> send(self(), {:evt, event}) end
        )

      if retried? do
        assert {:ok, _} = outcome
        assert attempts(agent) == 2
        assert [{1, 3, {:http, ^status}}] = retry_events()
      else
        assert {:error, {:model_request_failed, {:http_error, ^status, _}}, _} = outcome
        assert attempts(agent) == 1
        assert retry_events() == []
      end
    end
  end

  test "exhausted retries surface the last failure uniformly", %{agent: agent} do
    script = fn _n -> {:error, {:transport_error, :timeout}} end

    assert {:error, {:model_request_failed, {:transport_error, :timeout}}, _result} =
             Alto.run("retry me",
               provider: {ScriptedProvider, test_pid: self(), agent: agent, script: script},
               tools: [],
               provider_retries: 2,
               event_sink: fn event -> send(self(), {:evt, event}) end
             )

    assert attempts(agent) == 3
    assert [{1, 3, :transport}, {2, 3, :transport}] = retry_events()
  end

  test "retry stays off unless configured", %{agent: agent} do
    script = fn _n -> {:error, {:transport_error, :boom}} end

    assert {:error, {:model_request_failed, {:transport_error, :boom}}, _} =
             Alto.run("retry me",
               provider: {ScriptedProvider, test_pid: self(), agent: agent, script: script},
               tools: []
             )

    assert attempts(agent) == 1
  end

  test "our own deadline is never retried" do
    # SleepyProvider outlives the deadline; the timeout must surface once,
    # not as four attempts.
    assert {:error, {:model_process_failed, :timeout}, _} =
             Alto.run("retry me",
               provider: {SleepyProvider, []},
               tools: [],
               provider_timeout: 100,
               provider_retries: 3
             )
  end

  test "invalid retry budgets fail closed at construction", %{agent: agent} do
    script = fn _n -> {:ok, %{message: "x", tool_calls: []}} end

    assert {:error, {:invalid_option, :provider_retries, -1}, _} =
             Alto.run("retry me",
               provider: {ScriptedProvider, test_pid: self(), agent: agent, script: script},
               tools: [],
               provider_retries: -1
             )
  end

  test "cancellation wins during backoff", %{agent: agent} do
    script = fn _n -> {:error, {:transport_error, :down}} end

    {:ok, handle} =
      Alto.start("retry me",
        provider: {ScriptedProvider, test_pid: self(), agent: agent, script: script},
        tools: [],
        provider_retries: 100
      )

    assert_receive {:attempt, 0}, 2_000
    assert :ok = Alto.cancel(handle, :operator_stop)
    assert {:error, {:cancelled, :operator_stop}, _} = Alto.await(handle, 10_000)
  end

  test "tool effects are never retried" do
    test_pid = self()

    assert {:ok, result} =
             Alto.run("use the tool",
               provider: {ToolThenAnswerProvider, test_pid: test_pid},
               tools: [BoomTool],
               provider_retries: 3,
               event_sink: fn event -> send(test_pid, {:evt, event}) end
             )

    assert result.output == "recovered"
    assert_received :provider_called
    assert_received :provider_called
    refute_received :provider_called
    assert retry_events() == []
  end

  defp attempts(agent), do: Agent.get(agent, & &1)

  defp retry_events do
    for {:evt, %Event{type: :model_retry, data: data}} <- received_events() do
      {data.attempt, data.max_attempts, data.kind}
    end
  end

  defp received_events do
    Enum.reverse(collect_events([]))
  end

  defp collect_events(acc) do
    receive do
      {:evt, event} -> collect_events([{:evt, event} | acc])
    after
      100 -> acc
    end
  end
end
