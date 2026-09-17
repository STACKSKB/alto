defmodule Alto.Runner.ResumeContextIdentityTest do
  use ExUnit.Case, async: true

  alias Alto.Test.ResumeContextFixture, as: Fixture

  defmodule DescribedProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{context_window: 4_096, model: "advertised-default"}
    defdelegate stream(request, sink, opts), to: Fixture.Provider
  end

  defmodule UnknownProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{context_window: 4_096}
    defdelegate stream(request, sink, opts), to: Fixture.Provider
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-resume-identity-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    opts = [
      session: "identity-resume",
      session_dir: dir,
      provider: {DescribedProvider, []},
      tools: [Fixture.PayloadTool],
      loop: Alto.default_loop(context: Alto.Context.window(usage_estimation: true)),
      compaction: [strategy: {Fixture.Reducer, []}, keep_recent_messages: 1, max_compactions: 2]
    ]

    %{opts: opts}
  end

  defp compacted?(result), do: Enum.any?(result.events, &(&1.type == :context_compacted))

  defp seed(opts) do
    assert {:ok, result} = Alto.run("build authored history", opts)
    assert result.model_requests == 4
    refute compacted?(result)
    assert Alto.Context.Transcript.bytes(result.messages) > 4_096
  end

  test "advertised model without a model option survives durable resume", %{opts: opts} do
    seed(opts)
    assert {:ok, result} = Alto.resume(opts[:session], "continue", opts)
    refute compacted?(result)
  end

  test "unknown model preserves live estimation but cannot authorize durable reuse", %{opts: opts} do
    opts = Keyword.put(opts, :provider, {UnknownProvider, []})
    seed(opts)
    assert {:ok, result} = Alto.resume(opts[:session], "continue", opts)
    assert compacted?(result)
  end

  test "endpoint changes invalidate while credentials are not persisted", %{opts: opts} do
    provider_opts = [
      endpoint: "https://user-secret:password-secret@example.invalid/v1?key=query-secret",
      api_key: "api-key-secret",
      headers: [{"authorization", "header-secret"}]
    ]

    opts = Keyword.put(opts, :provider, {DescribedProvider, provider_opts})
    seed(opts)

    assert {:ok, snapshot} =
             Alto.Session.transcript(opts[:session], session_dir: opts[:session_dir])

    metadata = Map.get(snapshot, :context_observation)
    assert is_map(metadata)
    encoded = JSON.encode!(metadata)

    for secret <- [
          "user-secret",
          "password-secret",
          "query-secret",
          "api-key-secret",
          "header-secret"
        ] do
      refute String.contains?(encoded, secret)
    end

    # A log path is not model identity and must not invalidate the observation.
    same =
      Keyword.put(
        opts,
        :provider,
        {DescribedProvider, Keyword.put(provider_opts, :log_path, "other-log")}
      )

    assert {:ok, result} = Alto.resume(opts[:session], "continue", same)
    refute compacted?(result)

    changed =
      Keyword.put(
        opts,
        :provider,
        {DescribedProvider, Keyword.put(provider_opts, :endpoint, "https://elsewhere.invalid/v1")}
      )

    assert {:ok, result} = Alto.resume(opts[:session], "continue", changed)
    assert compacted?(result)
  end

  test "base URL changes invalidate an otherwise identical provider and model", %{opts: opts} do
    opts = Keyword.put(opts, :provider, {DescribedProvider, base_url: "https://first.invalid/v1"})
    seed(opts)

    changed =
      Keyword.put(opts, :provider, {DescribedProvider, base_url: "https://second.invalid/v1"})

    assert {:ok, result} = Alto.resume(opts[:session], "continue", changed)
    assert compacted?(result)
  end
end
