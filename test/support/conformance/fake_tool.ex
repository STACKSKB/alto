defmodule Alto.Conformance.FakeTool do
  @moduledoc """
  Scripted physical-action participants for failure conformance.

  The two tools record an authoritative external commit before timing out or
  crashing, proving that the runner classifies a lost response as unknown.

  Configure with `{Module, service: name, key: term(), test_pid: pid}`
  (all optional; `key` defaults to `"op"`, results echo the commit).
  """

  defmodule CommitThenTimeout do
    @moduledoc "Commits, then sleeps past the tool deadline (unknown outcome)."
    @behaviour Alto.Tool
    @impl true
    def name(_), do: :commit_then_timeout
    @impl true
    def schema(_), do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode(_), do: :exclusive
    @impl true
    def approval(_), do: :never
    @impl true
    def run(_args, _ctx, opts) do
      service = Keyword.get(opts, :service, Alto.Conformance.FakeService)
      key = Keyword.get(opts, :key, "op")
      test_pid = Keyword.get(opts, :test_pid)

      # Record the commit synchronously so the test can assert it even
      # though the runner will time this execution out as :unknown.
      {:ok, _} = Alto.Conformance.FakeService.commit(service, key)
      if test_pid, do: send(test_pid, {:committed, key})
      Process.sleep(10_000)
      {:ok, %{unreachable: true}}
    end
  end

  defmodule CommitThenCrash do
    @moduledoc "Commits, then crashes (unknown outcome)."
    @behaviour Alto.Tool
    @impl true
    def name(_), do: :commit_then_crash
    @impl true
    def schema(_), do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode(_), do: :exclusive
    @impl true
    def approval(_), do: :never
    @impl true
    def run(_args, _ctx, opts) do
      service = Keyword.get(opts, :service, Alto.Conformance.FakeService)
      key = Keyword.get(opts, :key, "op")
      test_pid = Keyword.get(opts, :test_pid)

      {:ok, _} = Alto.Conformance.FakeService.commit(service, key)
      if test_pid, do: send(test_pid, {:committed, key})
      exit(:boom_after_commit)
    end
  end
end
