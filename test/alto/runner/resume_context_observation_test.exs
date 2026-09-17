defmodule Alto.Runner.ResumeContextObservationTest do
  use ExUnit.Case, async: true

  alias Alto.Context.Transcript

  alias Alto.Test.ResumeContextFixture.{PayloadTool, Provider, OtherProvider, Reducer}

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-resume-usage-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    opts = [
      session: "observed-resume",
      session_dir: dir,
      provider: {Provider, model: "test-model"},
      tools: [PayloadTool],
      loop: Alto.default_loop(context: Alto.Context.window(usage_estimation: true)),
      compaction: [strategy: {Reducer, []}, keep_recent_messages: 1, max_compactions: 2]
    ]

    %{opts: opts}
  end

  defp compacted?(result), do: Enum.any?(result.events, &(&1.type == :context_compacted))

  defp seed(opts) do
    assert {:ok, result} = Alto.run("build authored history", opts)
    assert result.model_requests == 4
    refute compacted?(result)

    assert {:ok, snapshot} =
             Alto.Session.transcript(opts[:session], session_dir: opts[:session_dir])

    assert Transcript.bytes(snapshot.messages) > 4_096
    assert Enum.count(snapshot.messages, &(&1["role"] == "tool")) == 3
    snapshot
  end

  test "Session.transcript round trip preserves low observed usage on ordinary resume", %{
    opts: opts
  } do
    snapshot = seed(opts)
    assert {:ok, result} = Alto.run("continue", Keyword.put(opts, :resume, snapshot))
    refute compacted?(result)
    assert Enum.take(result.messages, length(snapshot.messages)) == snapshot.messages
    assert result.model_requests == 1
  end

  test "Alto.resume forwards observed usage rather than just transcript bytes", %{opts: opts} do
    snapshot = seed(opts)
    assert {:ok, result} = Alto.resume(opts[:session], "continue", opts)
    refute compacted?(result)
    assert Enum.take(result.messages, length(snapshot.messages)) == snapshot.messages
  end

  test "actual observed pressure still compacts on resume", %{opts: opts} do
    opts =
      Keyword.put(
        opts,
        :provider,
        {Provider, model: "test-model", final_usage: %{input_tokens: 4_090}}
      )

    seed(opts)
    assert {:ok, result} = Alto.resume(opts[:session], "continue", opts)
    assert compacted?(result)
  end

  test "settled history boundaries preserve observations for resume", %{opts: opts} do
    opts = Keyword.put(opts, :session_history, :settled)
    snapshot = seed(opts)
    assert is_map(snapshot.context_observation)
    assert {:ok, result} = Alto.resume(opts[:session], "continue", opts)
    refute compacted?(result)
  end

  test "corrupt optional observation metadata falls back without rejecting the transcript", %{
    opts: opts
  } do
    for change <- [:missing, :version, :count, :tokens, :prefix, :tools] do
      local = Keyword.put(opts, :session, "corrupt-#{change}")
      snapshot = seed(local)
      metadata = snapshot.context_observation

      broken =
        case change do
          :missing -> nil
          :version -> Map.put(metadata, "v", 99)
          :count -> Map.put(metadata, "messages_count", "4")
          :tokens -> Map.put(metadata, "input_tokens", -1)
          :prefix -> Map.put(metadata, "prefix_sha256", "invalid")
          :tools -> Map.put(metadata, "tools_sha256", "invalid")
        end

      snapshot = Map.put(snapshot, :context_observation, broken)
      assert {:ok, result} = Alto.run("continue", Keyword.put(local, :resume, snapshot))
      assert compacted?(result)
    end
  end

  test "missing or invalid final counts fall back conservatively", %{opts: opts} do
    for usage <- [nil, %{}, %{input_tokens: 0}, %{input_tokens: -1}, %{input_tokens: "100"}] do
      local =
        opts
        |> Keyword.put(:session, "missing-#{System.unique_integer([:positive])}")
        |> Keyword.put(:provider, {Provider, model: "test-model", final_usage: usage})

      seed(local)
      assert {:ok, result} = Alto.resume(local[:session], "continue", local)

      assert compacted?(result),
             "invalid usage must not authorize a smaller estimate: #{inspect(usage)}"
    end
  end

  test "changed model, provider, tools or observed history invalidates the estimate", %{
    opts: opts
  } do
    for change <- [:model, :provider, :tools, :history, :disabled] do
      # Keep normal session-backed compaction available. Each case owns its
      # transcript revision and must not inherit a previous case's reduction.
      local =
        Keyword.put(opts, :session, "changed-#{change}-#{System.unique_integer([:positive])}")

      snapshot = seed(local)

      {local, history} =
        case change do
          :model ->
            {Keyword.put(local, :provider, {Provider, model: "other-model"}), snapshot}

          :provider ->
            {Keyword.put(local, :provider, {OtherProvider, model: "test-model"}), snapshot}

          :tools ->
            {Keyword.put(local, :tools, []), snapshot}

          :history ->
            messages =
              List.update_at(snapshot.messages, 0, &Map.put(&1, "content", "changed history"))

            {local,
             %{snapshot | messages: messages, transcript_bytes: Transcript.bytes(messages)}}

          :disabled ->
            loop = Alto.default_loop(context: Alto.Context.window(usage_estimation: false))
            {Keyword.put(local, :loop, loop), snapshot}
        end

      assert {:ok, result} = Alto.run("continue", Keyword.put(local, :resume, history))
      assert compacted?(result), "changed #{change} must invalidate observed usage"
    end
  end
end
