defmodule Alto.Conformance.FakeTool do
  @moduledoc """
  Scripted physical-action participants for failure conformance.

  Each tool is a thin connector over `Alto.Conformance.FakeService`: the
  adapter stays local to its participant (service server + key), while any
  mapping logic lives in the calling loop or handler — never in hidden
  harness policy. All tools are `:exclusive` and `:required`-approval by
  omission where mutating, matching the prepared-operation boundary; the
  suite passes explicit approval in tests.

  Modes (one module each, so the script is visible in the test):

    * `RecordCommit` — commits once, succeeds (`:completed`);
    * `FailKnown` — explicit participant error, no commit (`:failed_known`);
    * `CommitThenTimeout` — commits, then sleeps past `tool_timeout`
      (`:unknown`: committed-but-unacknowledged);
    * `CommitThenCrash` — commits, then exits (`:unknown`).

  Configure with `{Module, service: name, key: term(), test_pid: pid}`
  (all optional; `key` defaults to `"op"`, results echo the commit).
  """

  defmodule RecordCommit do
    @moduledoc "Commits once to the fake service, then succeeds."
    @behaviour Alto.Tool
    @impl true
    def name, do: :record_commit
    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode, do: :exclusive
    @impl true
    def approval, do: :never
    @impl true
    def run(_args, _ctx, opts) do
      service = Keyword.get(opts, :service, Alto.Conformance.FakeService)
      key = Keyword.get(opts, :key, "op")
      Alto.Conformance.FakeService.call(service, key, %{})
    end

    @impl true
    def run(_args, _ctx), do: run(%{}, %{}, [])
  end

  defmodule FailKnown do
    @moduledoc "Participant-reported failure with no commit."
    @behaviour Alto.Tool
    @impl true
    def name, do: :fail_known
    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode, do: :exclusive
    @impl true
    def approval, do: :never
    @impl true
    def run(_args, _ctx, _opts), do: {:error, :downstream_rejected}
    @impl true
    def run(_args, _ctx), do: {:error, :downstream_rejected}
  end

  defmodule CommitThenTimeout do
    @moduledoc "Commits, then sleeps past the tool deadline (unknown outcome)."
    @behaviour Alto.Tool
    @impl true
    def name, do: :commit_then_timeout
    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode, do: :exclusive
    @impl true
    def approval, do: :never
    @impl true
    def run(_args, _ctx, opts) do
      service = Keyword.get(opts, :service, Alto.Conformance.FakeService)
      key = Keyword.get(opts, :key, "op")
      test_pid = Keyword.get(opts, :test_pid)

      # Record the commit synchronously so the test can assert it even
      # though the runner will time this execution out as :unknown.
      {:ok, _} = Alto.Conformance.FakeService.call(service, key, %{})
      if test_pid, do: send(test_pid, {:committed, key})
      Process.sleep(10_000)
      {:ok, %{unreachable: true}}
    end

    @impl true
    def run(_args, _ctx), do: run(%{}, %{}, [])
  end

  defmodule CommitThenCrash do
    @moduledoc "Commits, then crashes (unknown outcome)."
    @behaviour Alto.Tool
    @impl true
    def name, do: :commit_then_crash
    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode, do: :exclusive
    @impl true
    def approval, do: :never
    @impl true
    def run(_args, _ctx, opts) do
      service = Keyword.get(opts, :service, Alto.Conformance.FakeService)
      key = Keyword.get(opts, :key, "op")
      test_pid = Keyword.get(opts, :test_pid)

      {:ok, _} = Alto.Conformance.FakeService.call(service, key, %{})
      if test_pid, do: send(test_pid, {:committed, key})
      exit(:boom_after_commit)
    end

    @impl true
    def run(_args, _ctx), do: run(%{}, %{}, [])
  end
end
