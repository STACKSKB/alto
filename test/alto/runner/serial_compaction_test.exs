defmodule Alto.Runner.SerialCompactionTest do
  @moduledoc """
  Bounded recovery compaction: a single summarization pass when the transcript
  ceiling hits, degrading to the pre-compaction error on any failure — never
  a retry loop, never silent history loss.
  """

  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.Session

  defmodule EchoTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :echo

    @impl true
    def schema do
      %{
        description: "Echo a value.",
        parameters: %{
          type: "object",
          properties: %{value: %{type: "string"}},
          required: ["value"]
        }
      }
    end

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :never

    @impl true
    def run(%{"value" => value}, _context), do: {:ok, %{echo: value}}
  end

  defmodule ScriptedProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:stream_call, request.messages})

      cond do
        summarize?(request.messages) ->
          {:ok, %{message: "squib summary", tool_calls: []}}

        tool_message?(request.messages) ->
          {:ok, %{message: String.duplicate("f", 150), tool_calls: []}}

        true ->
          {:ok,
           %{
             message: nil,
             tool_calls: [%{id: "c1", name: "echo", arguments_json: ~s({"value":"hi"})}]
           }}
      end
    end

    defp summarize?(messages) do
      Enum.any?(messages, fn
        %{"role" => "user", "content" => "Summarize this agent work" <> _} -> true
        _other -> false
      end)
    end

    defp tool_message?(messages), do: Enum.any?(messages, &(&1["role"] == "tool"))
  end

  defmodule SummaryTextProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, _opts) do
      if Enum.any?(request.messages, fn
           %{"role" => "user", "content" => "Summarize this agent work" <> _} -> true
           _other -> false
         end) do
        {:ok, %{message: "squib", tool_calls: []}}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [%{id: "c1", name: "echo", arguments_json: ~s({"value":"hi"})}]
         }}
      end
    end
  end

  defmodule FailingSummaryProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, _opts) do
      if Enum.any?(request.messages, fn
           %{"role" => "user", "content" => "Summarize this agent work" <> _} -> true
           _other -> false
         end) do
        {:error, :kaput}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [%{id: "c1", name: "echo", arguments_json: ~s({"value":"hi"})}]
         }}
      end
    end
  end

  defmodule HandoffProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, _opts) do
      cond do
        Enum.any?(request.messages, fn
          %{"role" => "user", "content" => "Prepare a context handoff" <> _} -> true
          _other -> false
        end) ->
          {:ok,
           %{
             message:
               JSON.encode!(%{
                 design: "Keep the runtime bounded.",
                 pointers: "lib/alto/runner/serial.ex",
                 handoff: "The echo tool completed.",
                 next_step: "Return the final answer."
               }),
             tool_calls: []
           }}

        Enum.any?(request.messages, &(&1["role"] == "tool")) ->
          {:ok, %{message: String.duplicate("f", 50), tool_calls: []}}

        true ->
          {:ok,
           %{
             message: nil,
             tool_calls: [%{id: "c1", name: "echo", arguments_json: ~s({"value":"hi"})}]
           }}
      end
    end
  end

  defmodule AlwaysToolProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, _opts) do
      {:ok,
       %{
         message: nil,
         tool_calls: [%{id: "c1", name: "echo", arguments_json: ~s({"value":"hi"})}]
       }}
    end
  end

  defmodule CustomReducer do
    @behaviour Alto.Context.Compaction
    def request(input, _limit, opts) do
      send(opts[:owner], {:custom_input, input})

      {:ok,
       %{messages: [%{"role" => "user", "content" => "Summarize this agent work: " <> input}]}}
    end

    def decode(%{message: content}, _limit, _opts), do: {:ok, "Domain state: " <> content}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-compact-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp base_opts(extra) do
    [provider: {ScriptedProvider, test_pid: self()}, tools: [EchoTool]] ++ extra
  end

  test "one compaction recovers the run and records the summary fact", %{dir: dir} do
    # A large task message fills the budget so the final answer overflows it.
    assert {:ok, result} =
             Alto.run(
               String.duplicate("t", 200),
               base_opts(
                 max_transcript_bytes: 500,
                 compaction: [keep_recent_messages: 1, max_summary_bytes: 200],
                 session: :new,
                 session_dir: dir
               )
             )

    assert result.output == String.duplicate("f", 150)
    # Two model steps plus the single summarization call.
    assert result.model_requests == 3

    assert %Event{type: :context_compacted, data: data} =
             Enum.find(result.events, &(&1.type == :context_compacted))

    assert data.dropped_messages == 1
    assert :ok = Alto.Context.Transcript.validate(result.messages)
    assert data.summary_bytes > 0

    assert Enum.any?(result.messages, fn
             %{"role" => "user", "content" => "[alto compaction" <> _} -> true
             _other -> false
           end)

    assert {:ok, records} = Session.read(result.session_id, session_dir: dir)

    assert %{"type" => "compaction", "summary" => "squib summary"} =
             Enum.find(records, &(&1["type"] == "compaction"))
  end

  test "a caller composes a domain-specific context reducer", %{dir: dir} do
    assert {:ok, result} =
             Alto.run(
               String.duplicate("t", 200),
               base_opts(
                 max_transcript_bytes: 520,
                 compaction: [
                   strategy: {CustomReducer, owner: self()},
                   keep_recent_messages: 1,
                   max_summary_bytes: 200
                 ],
                 session: :new,
                 session_dir: dir
               )
             )

    assert_received {:custom_input, input}
    assert String.contains?(input, String.duplicate("t", 200))
    assert Enum.any?(result.messages, &String.contains?(&1["content"] || "", "Domain state:"))
    assert :ok = Alto.Context.Transcript.validate(result.messages)
  end

  test "compaction cannot make an extra provider call past the global budget", %{dir: dir} do
    assert {:error, _, result} =
             Alto.run(
               String.duplicate("t", 200),
               base_opts(
                 max_model_requests: 2,
                 max_transcript_bytes: 500,
                 compaction: [keep_recent_messages: 1],
                 session: :new,
                 session_dir: dir
               )
             )

    assert_received {:stream_call, _}
    assert_received {:stream_call, _}
    refute_received {:stream_call, _}
    refute Enum.any?(result.events, &(&1.type == :context_compacted))
  end

  test "a second ceiling hit fails closed instead of looping", %{dir: dir} do
    assert {:error, {:transcript_limit, 400}, result} =
             Alto.run("go",
               provider: {SummaryTextProvider, []},
               tools: [EchoTool],
               max_transcript_bytes: 400,
               compaction: [keep_recent_messages: 1, max_summary_bytes: 200],
               session: :new,
               session_dir: dir
             )

    compacted = Enum.filter(result.events, &(&1.type == :context_compacted))
    assert length(compacted) == 1
  end

  test "handoff strategy creates structured artifacts and a generated next step", %{dir: dir} do
    assert {:ok, result} =
             Alto.run(String.duplicate("t", 300),
               provider: {HandoffProvider, []},
               tools: [EchoTool],
               max_transcript_bytes: 600,
               compaction: [
                 strategy: :handoff,
                 keep_recent_messages: 1,
                 max_handoff_bytes: 400,
                 artifact_dir: Path.join(dir, "h")
               ],
               session: :new,
               session_dir: dir
             )

    assert result.output == String.duplicate("f", 50)
    assert :ok = Alto.Context.Transcript.validate(result.messages)

    assert %Event{data: data} =
             Enum.find(result.events, &(&1.type == :context_handoff_created))

    assert data.next_step == "Return the final answer."
    assert File.read!(data.files.design) == "Keep the runtime bounded.\n"
    assert File.read!(data.files.pointers) == "lib/alto/runner/serial.ex\n"
    assert Enum.any?(result.messages, &String.contains?(&1["content"] || "", "# Next step"))

    assert {:ok, records} = Session.read(result.session_id, session_dir: dir)

    assert %{"type" => "handoff", "next_step" => "Return the final answer."} =
             Enum.find(records, &(&1["type"] == "handoff"))
  end

  test "compaction stays off unless enabled", %{dir: dir} do
    test_pid = self()

    assert {:error, {:transcript_limit, 400}, _result} =
             Alto.run("go",
               provider: {AlwaysToolProvider, []},
               tools: [EchoTool],
               max_transcript_bytes: 400,
               session: :new,
               session_dir: dir,
               event_sink: fn event -> send(test_pid, {:evt, event}) end
             )

    refute_received {:evt, %Event{type: :context_compacting}}
  end

  test "compaction without a session fails closed", %{dir: dir} do
    assert {:error, :compaction_requires_session, _result} =
             Alto.run(
               "go",
               base_opts(max_transcript_bytes: 200, compaction: true, session_dir: dir)
             )
  end

  test "a failed summary degrades to the transcript error with an event", %{dir: dir} do
    assert {:error, {:transcript_limit, 500}, result} =
             Alto.run("go",
               provider: {FailingSummaryProvider, []},
               tools: [EchoTool],
               max_transcript_bytes: 500,
               compaction: [keep_recent_messages: 1, max_summary_bytes: 200],
               session: :new,
               session_dir: dir
             )

    assert Enum.any?(result.events, &(&1.type == :context_compact_failed))
  end

  test "invalid compaction and retry options fail closed at construction" do
    assert {:error, {:invalid_compaction, _}, _} =
             Alto.run("go", base_opts(compaction: [keep_recent_messages: 0]))

    assert {:error, {:invalid_compaction, _}, _} = Alto.run("go", base_opts(compaction: "yes"))

    assert {:error, {:invalid_option, :provider_retries, -1}, _} =
             Alto.run("go", base_opts(provider_retries: -1))
  end
end
