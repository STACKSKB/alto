defmodule Alto.Providers.PrefixContinuityTest do
  use ExUnit.Case, async: true

  alias Alto.Providers.PrefixContinuity

  test "first request is unobserved, not a claimed cold start or invalidation" do
    report = PrefixContinuity.report(request())
    assert report.comparison == :unavailable
  end

  test "append-only requests preserve the previous successful serialized prefix" do
    previous = request()
    next = Map.put(previous, :context_observation, previous)
    next = %{next | messages: next.messages ++ [%{"role" => "assistant", "content" => "next"}]}
    report = PrefixContinuity.report(next)
    assert report.comparison == :preserved
    assert report.compared_prefix_sha256 == report.previous_messages_sha256
    assert report.messages_sha256 != report.previous_messages_sha256
    assert report.tools_unchanged
  end

  test "edits, truncation, tool schema edits and reordering are visible without body logs" do
    previous = request()
    base = Map.put(previous, :context_observation, previous)

    for changed <- [
          %{base | messages: tl(base.messages)},
          %{base | messages: Enum.reverse(base.messages)},
          %{base | messages: [%{"role" => "system", "content" => "edited"} | tl(base.messages)]},
          %{base | tools: Enum.reverse(base.tools)},
          %{base | tools: []}
        ] do
      report = PrefixContinuity.report(changed)
      assert report.comparison == :changed
      serialized = JSON.encode!(report)
      refute serialized =~ "PRIVATE-BODY"
      refute serialized =~ "PRIVATE-SCHEMA"
    end
  end

  test "continuity is independent of usage and does not promise provider cache hits" do
    previous = request()
    observation = Map.merge(previous, %{input_tokens: 100, cached_input_tokens: 0})
    report = PrefixContinuity.report(Map.put(previous, :context_observation, observation))
    assert report.comparison == :preserved
    refute Map.has_key?(report, :cache_hit)
  end

  defmodule Provider do
    def describe(_opts), do: %{}

    def stream(_request, _sink, _opts) do
      {:ok,
       %{
         message: "done",
         tool_calls: [],
         usage: %{"prompt_tokens" => 100, "prompt_tokens_details" => %{"cached_tokens" => 0}}
       }}
    end
  end

  test "profile composition observes requests without adding diagnostics to executor events" do
    parent = self()

    assert {:ok, _} =
             Alto.run("PRIVATE-BODY",
               provider:
                 Alto.Providers.Observe.wrap(Provider, fn request ->
                   send(parent, {:prefix, PrefixContinuity.report(request)})
                 end),
               tools: [],
               event_sink: fn event -> send(parent, {:event, event}) end
             )

    assert_receive {:event, %Alto.Event{type: :model_started, data: %{step: 1} = data}}
    refute Map.has_key?(data, :prefix)
    assert_receive {:prefix, report}
    assert report.comparison == :unavailable
    refute JSON.encode!(report) =~ "PRIVATE-BODY"

    assert_receive {:event,
                    %Alto.Event{
                      type: :model_completed,
                      data: %{usage: %{input_tokens: 100, cached_input_tokens: 0}}
                    }}
  end

  defp request do
    %{
      messages: [
        %{"role" => "system", "content" => "PRIVATE-BODY"},
        %{"role" => "user", "content" => "hello"}
      ],
      tools: [
        %{"function" => %{"name" => "one", "description" => "PRIVATE-SCHEMA"}},
        %{"function" => %{"name" => "two"}}
      ]
    }
  end
end
