defmodule Alto.TUI.AttachmentsTest do
  use ExUnit.Case, async: true
  alias Alto.{Attachment, Content}
  alias Alto.TUI.{App, Attachments, State, View}
  alias ExRatatui.Event.{Key, Mouse, Paste}

  setup do
    root =
      Path.join(System.tmp_dir!(), "alto-tui-attachments-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, state} =
      State.new(
        [
          provider: nil,
          tui_backends: [alto: {Alto.TUI.Backends.Native, []}],
          session_dir: Path.join(root, "sessions"),
          tui: [paste_inline_bytes: 40, paste_chunk_bytes: 32]
        ],
        project: root,
        path: Path.join(root, "catalog.json"),
        test_mode: true
      )

    %{state: state, root: root}
  end

  test "small pastes stay inline and large pastes become editable files", %{state: state} do
    {:noreply, state} = App.handle_event(%Paste{content: "Explain: "}, state)
    text = String.duplicate("猫🙂\n", 40)
    {:noreply, state} = App.handle_event(%Paste{content: text}, state)
    assert length(state.attachments) > 1
    draft = ExRatatui.textarea_get_value(state.textarea)
    assert String.starts_with?(draft, "Explain: ")
    assert byte_size(draft) < byte_size(text)
    assert Enum.map_join(state.attachments, &File.read!(&1.path)) == text
    {:noreply, menu} = App.handle_event(%Key{code: "f7"}, state)
    assert menu.overlay.kind == :attachments
    attachment = hd(state.attachments)
    editor = Attachments.edit(menu, attachment)
    terminal = ExRatatui.init_test_terminal(120, 36)
    assert :ok = ExRatatui.draw(terminal, View.widgets(editor, %{width: 120, height: 36}))
    assert ExRatatui.get_buffer_content(terminal) =~ "save"
    assert View.hit_target(editor, 120, 36, 5, 5) == :overlay

    {:noreply, editor} =
      App.handle_event(%Mouse{kind: "down", button: "left", x: 5, y: 5}, editor)

    ExRatatui.textarea_set_value(editor.overlay.textarea, "edited\n")
    {:noreply, saved} = App.handle_event(%Key{code: "s", modifiers: ["ctrl"]}, editor)
    assert saved.overlay.kind == :attachments
    assert File.read!(attachment.path) == "edited\n"
    {:ok, %Content{} = snapshot} = Attachments.prepare(saved, draft)
    assert Enum.at(snapshot.blocks, 1)["text"] == "Attached file: paste-1.txt\nedited\n"
    assert {:ok, _} = Attachment.update(hd(saved.attachments), "later edit")
    assert Enum.at(snapshot.blocks, 1)["text"] =~ "edited\n"
    refute Enum.at(snapshot.blocks, 1)["text"] =~ "later edit"
  end

  test "image clipboard paste keeps one stable private file and image content", %{state: state} do
    signature = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
    ihdr = <<1::32, 1::32, 8, 2, 0, 0, 0>>
    image = signature <> <<13::32, "IHDR", ihdr::binary, :erlang.crc32(["IHDR", ihdr])::32>>
    state = %{state | clipboard_read: fn -> {:ok, {:image, image, "image/png"}} end}
    {:noreply, state} = App.handle_event(%Key{code: "v", modifiers: ["ctrl"]}, state)
    assert [attachment] = state.attachments
    assert File.read!(attachment.path) == image
    refute attachment.editable?
    draft = ExRatatui.textarea_get_value(state.textarea)

    assert {:ok, %Content{blocks: [_, %{"type" => "image", "data" => encoded}]}} =
             Attachments.prepare(state, draft)

    assert Base.decode64!(encoded) == image
    assert {:ok, _} = Attachments.prepare(state, draft)
    assert [again] = state.attachments
    assert again.path == attachment.path
    removed = Attachments.remove(state, attachment)
    assert Attachments.active(removed) == []
    assert {:ok, ""} = Attachments.prepare(removed, "")
  end

  test "deleting a token excludes it and unreadable attachments preserve the draft", %{
    state: state
  } do
    state = Attachments.paste(state, String.duplicate("x", 100))
    [first | _] = state.attachments
    draft = ExRatatui.textarea_get_value(state.textarea)

    ExRatatui.textarea_set_value(
      state.textarea,
      String.replace(draft, Attachment.token(first), "")
    )

    refute first in Attachments.active(state)
    missing = List.last(state.attachments)
    File.rm!(missing.path)

    assert {:error, :enoent} =
             Attachments.prepare(state, ExRatatui.textarea_get_value(state.textarea))

    before = ExRatatui.textarea_get_value(state.textarea)
    {:noreply, next} = App.handle_event(%Key{code: "enter"}, state)
    assert next.notice =~ "draft kept"
    assert ExRatatui.textarea_get_value(next.textarea) == before
    assert next.runs == %{}
  end

  test "binary uploads copy the original and generated files have visible paths", %{
    root: root,
    state: state
  } do
    path = Path.join(root, "input.pdf")
    File.write!(path, "%PDF-1.7\ninput")
    state = Attachments.upload(state, path)
    assert [file] = state.attachments
    assert file.path != path

    output =
      Content.new([
        Content.artifact(
          "output.docx",
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
          Base.encode64(<<80, 75, 0, 255>>)
        )
      ])

    state = Attachments.outputs(state, nil, output)
    assert [entry] = State.current_entries(state)
    assert entry.text =~ "output.docx"
    output_path = entry.text |> String.split("\n") |> List.last()
    assert File.read!(output_path) == <<80, 75, 0, 255>>
  end

  test "saved output bytes recreate missing files on transcript reload", %{
    root: root,
    state: state
  } do
    blocks = [
      Content.artifact("answer.pdf", "application/pdf", Base.encode64("%PDF-1.7\nanswer"))
    ]

    messages = [%{"role" => "assistant", "content" => blocks}]
    directory = Path.join(root, "saved-outputs")
    entries = Alto.ToolDisplay.transcript(messages, attachment_directory: directory)
    path = entries |> List.last() |> Map.fetch!(:text) |> String.split("\n") |> List.last()
    assert File.read!(path) == "%PDF-1.7\nanswer"
    File.rm!(path)
    assert Alto.ToolDisplay.transcript(messages, attachment_directory: directory) == entries
    assert File.read!(path) == "%PDF-1.7\nanswer"

    assert :ok =
             Attachments.validate_provider(Content.new(blocks), {Alto.Providers.Anthropic, []})

    uploaded =
      Content.new([Content.file("file.pdf", "application/pdf", Base.encode64("%PDF-1.7"))])

    assert {:error, :model_does_not_support_files} =
             Attachments.validate_provider(uploaded, {Alto.Providers.Anthropic, []})

    assert :ok =
             Attachments.validate_provider(
               uploaded,
               {Alto.Providers.Anthropic, supports_files: true}
             )

    assert state.attachments == []
  end

  test "submitting a running task freezes paste files in the input queue", %{state: state} do
    state = %{state | selected_task_id: "task", runs: %{"run" => %{task_id: "task"}}}
    original = String.duplicate("pasted text\n", 12)
    state = Attachments.paste(state, original)
    files = state.attachments
    {:noreply, queued} = App.handle_event(%Key{code: "enter"}, state)
    assert queued.notice =~ "message queued"
    assert queued.attachments == []
    assert ExRatatui.textarea_get_value(queued.textarea) == ""
    input = queued.inputs["task"]
    on_exit(fn -> Alto.Input.close(input) end)
    assert [entry] = Alto.Input.request(input, :list)
    assert entry.content |> Enum.drop(1) |> Enum.map_join(& &1["text"]) =~ "pasted text"
    assert {:ok, _} = Attachment.update(hd(files), "changed after sending")
    refute Content.text_value(entry.content) =~ "changed after sending"

    [replayed] = Alto.ToolDisplay.transcript([%{"role" => "user", "content" => entry.content}])
    assert replayed.text =~ "paste-1.txt"
    refute replayed.text =~ "pasted text"
  end

  test "ordinary tool lists keep their usual display without attachment errors", %{state: state} do
    state = %{state | selected_task_id: "task", runs: %{"run" => %{task_id: "task"}}}
    event = Alto.Event.durable(:tool_completed, %{name: "list", call_id: "call", value: [1, 2]})
    {:noreply, next} = App.handle_info({:alto_tui_event, "run", event}, state)
    assert next.notice == state.notice
    assert [%{kind: :tool}] = State.current_entries(next)
  end

  test "unsupported media preserves the draft for new runs and checks the running model for queues",
       %{state: state} do
    profile = %Alto.Harness.ProviderProfile{
      id: "models",
      provider: {Alto.Providers.OpenAICompatible, model: "vision", supports_images: true},
      models: [
        %{id: "text", input_modalities: ["text"]},
        %{id: "vision", input_modalities: ["text", "image"]}
      ]
    }

    signature = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
    ihdr = <<1::32, 1::32, 8, 2, 0, 0, 0>>
    png = signature <> <<13::32, "IHDR", ihdr::binary, :erlang.crc32(["IHDR", ihdr])::32>>
    state = %{state | profiles: [profile], selected_provider_id: "models", selected_model: "text"}
    state = Attachments.paste_image(state, png, "image/png")
    draft = ExRatatui.textarea_get_value(state.textarea)
    {:noreply, denied} = App.handle_event(%Key{code: "enter"}, state)
    assert denied.runs == %{}
    assert denied.notice =~ "draft kept"
    assert denied.attachments == state.attachments
    assert ExRatatui.textarea_get_value(denied.textarea) == draft

    running = %{
      denied
      | selected_task_id: "task",
        selected_model: "vision",
        runs: %{
          "run" => %{
            task_id: "task",
            input_provider: {Alto.Providers.OpenAICompatible, input_modalities: ["text"]}
          }
        }
    }

    {:noreply, denied} = App.handle_event(%Key{code: "enter"}, running)
    assert denied.notice =~ "draft kept"
    refute Map.has_key?(denied.inputs, "task")
    assert ExRatatui.textarea_get_value(denied.textarea) == draft
  end
end
