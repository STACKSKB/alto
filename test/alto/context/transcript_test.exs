defmodule Alto.Context.TranscriptTest do
  use ExUnit.Case, async: true
  alias Alto.Context.Transcript

  defp call(ids), do: %{"role" => "assistant", "tool_calls" => Enum.map(ids, &%{"id" => &1})}
  defp reply(id), do: %{"role" => "tool", "tool_call_id" => id, "content" => "ok"}

  test "every recent-message cutoff retains complete parallel call groups" do
    messages = [
      %{"role" => "system", "content" => "policy"},
      %{"role" => "user", "content" => "task"},
      call(["a", "b"]),
      reply("b"),
      reply("a"),
      %{"role" => "assistant", "content" => "done"}
    ]

    for keep <- 1..length(messages) do
      {system, old, recent} = Transcript.split(messages, keep)
      assert :ok = Transcript.validate(system ++ old)
      assert :ok = Transcript.validate(system ++ recent)
      assert system ++ old ++ recent == messages
    end
  end

  test "interrupted effects close as unknown without inventing successful replies" do
    history = [call(["a", "b"]), reply("a")]
    assert {:error, {:unanswered_tool_calls, ["b"]}} = Transcript.validate(history)
    assert {:ok, completed} = Transcript.close_interrupted(history)
    assert :ok = Transcript.validate(completed)
    assert %{"tool_call_id" => "b", "content" => content} = List.last(completed)
    assert JSON.decode!(content)["outcome"] == "unknown"
  end

  test "orphan replies and a new message before tool settlement are rejected" do
    assert {:error, {:orphan_tool_reply, "missing"}} = Transcript.validate([reply("missing")])

    assert {:error, {:unanswered_tool_calls, ["a"]}} =
             Transcript.validate([call(["a"]), %{"role" => "user", "content" => "next"}])
  end
end
