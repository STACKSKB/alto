defmodule Alto.Runner.ChildSummaryTest do
  use ExUnit.Case, async: true

  alias Alto.Runner.Execution.Children
  alias Alto.Runner.Result
  alias Alto.Usage

  test "live and retained summaries produce the same public result and accounting" do
    result = %{
      Result.empty()
      | output: "done",
        verdict: :completed,
        model_requests: 2,
        usage: %{Usage.to_map(Usage.new()) | input_tokens: 7, requests: 1},
        persistence: {:degraded, [:transcript_write_failed]}
    }

    summary = Children.child_summary("worker", {:ok, result})
    initial = %{usage: Usage.new(), verdict: :empty, persistence_errors: []}
    live = Children.merge_child_summary(initial, summary)

    assert {:ok, [public], retained} = Children.merge_retained([{"worker", summary}], initial)
    assert public == Children.public_child_summary(summary)
    refute Map.has_key?(public, :persistence)
    assert retained == live
    assert retained.usage.input_tokens == 7
    assert retained.verdict == :completed
    assert retained.persistence_errors == [{:subagent, :transcript_write_failed}]
  end

  test "cancellation, pre-start failure, and process failure keep their accounting" do
    initial = %{usage: Usage.new(), verdict: :empty, persistence_errors: []}

    result = %{
      Result.empty()
      | usage: %{Usage.to_map(Usage.new()) | output_tokens: 3, requests: 1},
        verdict: :failed_known,
        persistence: {:degraded, [:write_failed]}
    }

    cancelled = Children.child_summary("cancelled", {:error, {:cancelled, :owner}, result})
    failed = Children.child_summary("failed", {:error, :provider_required})
    crashed = Children.child_summary("crashed", {:error, {:run_process_failed, :boom}, result})

    assert {:ok, _, retained} =
             Children.merge_retained(
               [{"cancelled", cancelled}, {"failed", failed}, {"crashed", crashed}],
               initial
             )

    live =
      [cancelled, failed, crashed]
      |> Enum.reduce(initial, &Children.merge_child_summary(&2, &1))

    assert retained == live
    assert retained.verdict == :unknown
    assert retained.usage.output_tokens == 3
    assert retained.persistence_errors == [{:subagent, :write_failed}]
  end

  test "retained summary rejects invalid accounting fields" do
    initial = %{usage: Usage.new(), verdict: :empty, persistence_errors: []}
    summary = Children.child_summary("worker", {:ok, Result.empty()})

    assert {:error, :invalid_retained_child_result} =
             Children.merge_retained(
               [{"worker", put_in(summary, [:usage, :requests], -1)}],
               initial
             )

    assert {:error, :invalid_retained_child_result} =
             Children.merge_retained([{"other", summary}], initial)
  end
end
