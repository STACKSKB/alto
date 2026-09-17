defmodule Alto.Runner.MultimodalTest do
  use ExUnit.Case, async: true

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aCFcAAAAASUVORK5CYII="

  defmodule Tool do
    @behaviour Alto.Tool
    def name, do: :picture
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    def approval, do: :never
    def execution_mode, do: :parallel
    def run(_, _, opts), do: {:ok, opts[:value]}
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _, opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")) or opts[:capture] do
        send(opts[:owner], {:request, request.messages})
        {:ok, %{message: "image received", tool_calls: []}}
      else
        {:ok, %{message: nil, tool_calls: [%{id: "pic", name: "picture", arguments_json: "{}"}]}}
      end
    end
  end

  defmodule Native do
    @behaviour Alto.Loop
    def init(_, _),
      do:
        Alto.Transition.continue(nil, [
          Alto.Effect.invoke_tool(%{name: "picture", arguments: %{}})
        ])

    def handle_event(%{type: :tool_completed}, state, _),
      do: Alto.Transition.continue(state, [Alto.Effect.request_model(%{})])

    def handle_event(%{type: :model_completed}, state, _), do: Alto.Transition.stop(state, :done)
  end

  defp content, do: Alto.Content.new([Alto.Content.image("image/png", @png, 1, 1)])

  test "typed image survives execution, parallel batches and transcript persistence" do
    dir = Path.join(System.tmp_dir!(), "alto-vision-run-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, result} =
             Alto.run("inspect",
               tool_presenter: {Alto.ToolDisplay, []},
               provider: {Provider, owner: self()},
               tools: [{Tool, value: content()}],
               loop: Alto.default_loop(tool_execution: {:parallel, 2}),
               session: :new,
               session_dir: dir
             )

    assert_receive {:request, messages}
    tool = Enum.find(messages, &(&1["role"] == "tool"))
    assert [%{"type" => "image", "data" => @png}] = tool["content"]
    event = Enum.find(result.events, &(&1.type == :tool_completed))
    assert %Alto.Content{} = event.data.value
    assert event.data.output == "Image · image/png · 1 × 1"
    refute event.data.output =~ @png
    assert {:ok, saved} = Alto.Session.transcript(result.session_id, session_dir: dir)
    assert Enum.find(saved.messages, &(&1["role"] == "tool"))["content"] == tool["content"]
  end

  test "typed payloads have no implicit presentation or base64 text projection" do
    assert {:ok, result} =
             Alto.run("inspect",
               provider: {Provider, owner: self()},
               tools: [{Tool, value: content()}]
             )

    event = Enum.find(result.events, &(&1.type == :tool_completed))
    assert event.data.output == ""
    assert event.data.value == content()
  end

  test "native tool content becomes a typed user context without orphan tool replies" do
    assert {:ok, _} =
             Alto.run("inspect",
               provider: {Provider, owner: self(), capture: true},
               tools: [{Tool, value: content()}],
               loop: Alto.loop(Native)
             )

    assert_receive {:request, messages}

    assert [%{"type" => "text"}, %{"type" => "image", "data" => @png}] =
             List.last(messages)["content"]

    assert :ok = Alto.Context.Transcript.validate(messages)
  end

  test "lookalike ordinary values stay text and invalid typed images fail before retention" do
    ordinary = %{blocks: [%{type: "image", data: @png}]}

    assert {:ok, _} =
             Alto.run("inspect",
               provider: {Provider, owner: self()},
               tools: [{Tool, value: ordinary}]
             )

    assert_receive {:request, messages}
    assert is_binary(Enum.find(messages, &(&1["role"] == "tool"))["content"])

    invalid = Alto.Content.new([Alto.Content.image("image/png", @png, 900_000, 1)])

    assert {:ok, result} =
             Alto.run("inspect",
               provider: {Provider, owner: self()},
               tools: [{Tool, value: invalid}]
             )

    assert Enum.any?(result.events, &(&1.type == :tool_failed))
    refute Enum.any?(result.events, &(&1.type == :tool_completed))
  end
end
