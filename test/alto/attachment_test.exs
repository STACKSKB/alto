defmodule Alto.AttachmentTest do
  use ExUnit.Case, async: true
  alias Alto.{Attachment, Content}

  setup do
    root = Path.join(System.tmp_dir!(), "alto-attachments-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, opts: [directory: Path.join(root, "files")]}
  end

  test "chunked pastes preserve UTF-8, CRLF and byte order and edit the same file", %{opts: opts} do
    text = String.duplicate("猫🙂abc\r\n", 12)
    assert {:ok, files} = Attachment.paste(text, opts ++ [chunk_bytes: 17])
    assert length(files) > 1
    assert Enum.all?(files, &(&1.size <= 17))
    assert Enum.map_join(files, &File.read!(&1.path)) == text
    assert Enum.all?(files, &String.valid?(File.read!(&1.path)))
    first = hd(files)
    assert {:ok, snapshot} = Attachment.content(first)
    assert {:ok, edited} = Attachment.update(first, "edited\n猫")
    assert edited.path == first.path
    assert File.read!(first.path) == "edited\n猫"
    assert snapshot != elem(Attachment.content(edited), 1)
    assert {:ok, info} = File.stat(first.path)
    assert Bitwise.band(info.mode, 0o777) == 0o600
    assert {:ok, directory} = File.stat(Path.dirname(first.path))
    assert Bitwise.band(directory.mode, 0o777) == 0o700
  end

  test "uploads snapshot the original and output recovery reuses a stable file", %{
    root: root,
    opts: opts
  } do
    original = Path.join(root, "report.pdf")
    File.write!(original, "%PDF-1.7\noriginal")
    assert {:ok, uploaded} = Attachment.upload(original, opts)
    File.write!(original, "%PDF-1.7\nchanged")
    assert {:ok, block} = Attachment.content(uploaded)
    assert Base.decode64!(block["data"]) == "%PDF-1.7\noriginal"
    assert block["media_type"] == "application/pdf"
    output = Content.new([Content.artifact("report.pdf", "application/pdf", block["data"])])
    assert {:ok, [first]} = Attachment.materialize(output, opts)
    File.rm!(first.path)
    assert {:ok, [again]} = Attachment.materialize(output, opts)
    assert again.path == first.path
    assert File.read!(again.path) == "%PDF-1.7\noriginal"
  end

  test "bounds and invalid file blocks fail before filesystem writes", %{opts: opts} do
    assert {:error, :attachment_too_large} =
             Attachment.stage("large", "file.txt", opts ++ [max_bytes: 2])

    assert {:error, :paste_too_large} = Attachment.paste(<<255>>, opts)
    refute File.exists?(opts[:directory])

    for block <- [
          Content.file("../bad", "application/pdf", Base.encode64("%PDF-")),
          Content.file("bad", "invalid", ""),
          Content.file("bad.pdf", "application/pdf", Base.encode64("wrong")),
          Content.file("bad", "application/octet-stream", "invalid base64")
        ] do
      assert {:error, _} = Content.decode_transcript([block])
    end
  end

  test "published binary artifacts are model-readable without native file support", %{root: root} do
    File.write!(Path.join(root, "report.docx"), <<80, 75, 0, 255>>)

    assert {:ok, %Content{} = content} =
             Alto.Tool.run(Alto.Tools.PublishFile, %{"path" => "report.docx"}, %{cwd: root})

    assert {:ok, blocks} =
             Content.map_media(content, %{images: false, files: false}, fn _ ->
               flunk("opaque bytes sent to provider")
             end)

    assert Enum.all?(blocks, &(&1["type"] == "text"))
    assert Content.text_value(blocks) =~ "report.docx"

    assert {:error, _} =
             Alto.Tool.run(Alto.Tools.PublishFile, %{"path" => "../outside"}, %{cwd: root})
  end
end
