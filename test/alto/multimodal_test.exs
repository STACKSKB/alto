defmodule Alto.MultimodalTest do
  use ExUnit.Case, async: true
  alias Alto.{Content, Input, Messaging, Session}

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:owner], {:request, request})
      {:ok, %{message: Keyword.get(opts, :message, "ok"), tool_calls: [], usage: %{}}}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-multimodal-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "typed user uploads and generated documents survive a saved session", %{root: root} do
    task =
      Content.new([
        Content.text("Read this"),
        Content.file("input.pdf", "application/pdf", Base.encode64("%PDF-1.7\ninput"))
      ])

    output = [
      Content.artifact(
        "answer.docx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        Base.encode64(<<80, 75, 0, 255>>)
      )
    ]

    result =
      Alto.run(task,
        provider: {Provider, owner: self(), message: output},
        session: :new,
        session_dir: root
      )

    assert result.status == :ok
    assert result.output == output
    assert_receive {:request, %{messages: [%{"role" => "user", "content" => blocks}]}}
    assert blocks == task.blocks
    assert {:ok, transcript} = Session.transcript(result.session_id, session_dir: root)
    assert List.last(transcript["messages"])["content"] == output
    assert {:ok, decoded} = Content.decode_transcript(output)
    assert decoded.blocks == output
  end

  test "queued uploads count toward capacity and remain typed at the next turn", %{root: root} do
    blocks = [
      Content.text("Follow up"),
      Content.file("input.pdf", "application/pdf", Base.encode64("%PDF-1.7\ninput"))
    ]

    {:ok, too_small} = Input.open(max_bytes: 20)

    assert {:error, :input_capacity} =
             Messaging.send(too_small, text: "next", content: blocks, delivery: :follow_up)

    Input.close(too_small)
    {:ok, input} = Input.open(max_bytes: 10_000)
    on_exit(fn -> Input.close(input) end)

    assert {:ok, receipt} =
             Messaging.send(input,
               text: "next",
               content: blocks,
               delivery: :follow_up,
               idempotency_key: "upload"
             )

    assert {:ok, same} =
             Messaging.send(input,
               text: "next",
               content: blocks,
               delivery: :follow_up,
               idempotency_key: "upload"
             )

    assert same == receipt
    assert {:ok, snapshot} = Input.request(input, :snapshot)
    assert snapshot.bytes > byte_size("next")
    result = Alto.run("first", provider: {Provider, owner: self()}, input: input, cwd: root)
    assert result.status == :ok
    assert result.model_requests == 2
    assert_receive {:request, %{messages: [%{"content" => "first"}]}}
    assert_receive {:request, %{messages: messages}}
    assert List.last(messages)["content"] == blocks
    assert Input.request(input, :list) == []
  end

  test "the wire protocol accepts validated typed uploads without changing text envelopes" do
    task = [
      Content.text("read"),
      Content.file("report.pdf", "application/pdf", Base.encode64("%PDF-1.7"))
    ]

    assert {:ok, {:start_run, "1", ["default", %Content{blocks: ^task}, nil]}} =
             Alto.Protocol.decode_command(
               JSON.encode!(%{v: 1, type: "start_run", id: "1", config: "default", task: task})
             )

    assert {:error, _} =
             Alto.Protocol.decode_command(
               JSON.encode!(%{
                 v: 1,
                 type: "start_run",
                 id: "1",
                 config: "default",
                 task: [Content.file("bad.pdf", "application/pdf", "invalid")]
               })
             )

    assert {:ok, {:start_run, "1", ["default", "read", nil]}} =
             Alto.Protocol.decode_command(
               JSON.encode!(%{v: 1, type: "start_run", id: "1", config: "default", task: "read"})
             )
  end

  test "the CLI accepts repeated local file uploads" do
    assert {:ok, options, ["summarize"]} =
             Alto.CLI.Arguments.parse(["--attach", "one.pdf", "--attach", "two.png", "summarize"])

    assert Keyword.get_values(options, :attach) == ["one.pdf", "two.png"]
  end

  test "the CLI does not treat ordinary loop output lists as attachments" do
    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             Alto.CLI.Renderer.finish([1, 2], false)
           end) == ""
  end
end
