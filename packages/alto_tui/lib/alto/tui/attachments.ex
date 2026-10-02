defmodule Alto.TUI.Attachments do
  @moduledoc "File-backed composer attachments, paste folding and in-place editing."
  alias Alto.Contrib.Attachment
  alias Alto.Content
  alias Alto.TUI.Menu
  alias Alto.TUI.State
  alias ExRatatui.Event.Key
  @max_draft_bytes 12_000_000
  @max_attachments 512

  def options(state),
    do: [directory: Path.join(Alto.Session.dir(state.catalog_opts), "attachments")]

  def paste(state, text) when is_binary(text) do
    cond do
      not String.valid?(text) ->
        error(state, :paste_must_be_utf8)

      byte_size(text) > 6_000_000 ->
        error(state, :paste_too_large)

      byte_size(text) + draft_bytes(state) > @max_draft_bytes ->
        error(state, :draft_too_large)

      byte_size(text) >= state.paste_inline_bytes or length(:binary.matches(text, "\n")) >= 20 ->
        case Attachment.paste(
               text,
               Keyword.put(options(state), :chunk_bytes, state.paste_chunk_bytes)
             ) do
          {:ok, attachments} -> add(state, attachments)
          {:error, reason} -> error(state, reason)
        end

      true ->
        ExRatatui.textarea_insert_str(state.textarea, text)
        %{state | focus: :composer}
    end
  end

  def paste_image(state, bytes, media) do
    name = if media == "image/jpeg", do: "pasted-image.jpg", else: "pasted-image.png"

    if byte_size(bytes) + draft_bytes(state) > @max_draft_bytes do
      error(state, :draft_too_large)
    else
      case Attachment.stage(bytes, name, Keyword.put(options(state), :media_type, media)) do
        {:ok, attachment} -> add(state, [attachment])
        {:error, reason} -> error(state, reason)
      end
    end
  end

  def upload(state, path) do
    project = State.selected_project(state)
    path = path |> String.trim() |> Path.expand((project && project["root"]) || File.cwd!())

    case Attachment.upload(path, options(state)) do
      {:ok, attachment} -> add(state, [attachment])
      {:error, reason} -> error(state, reason)
    end
  end

  defp draft_bytes(state),
    do:
      Enum.reduce(
        active(state),
        byte_size(ExRatatui.textarea_get_value(state.textarea)),
        &(&1.size + &2)
      )

  def active(state) do
    draft = ExRatatui.textarea_get_value(state.textarea)

    state.attachments
    |> Enum.filter(&String.contains?(draft, Attachment.token(&1)))
    |> Enum.sort_by(fn attachment ->
      {position, _} = :binary.match(draft, Attachment.token(attachment))
      position
    end)
  end

  defp add(state, attachments) do
    current = active(state)

    cond do
      length(current) + length(attachments) > @max_attachments ->
        error(state, :too_many_attachments)

      Enum.reduce(attachments, draft_bytes(state), &(&1.size + &2)) > @max_draft_bytes ->
        error(state, :draft_too_large)

      true ->
        tokens = Enum.map_join(attachments, " ", &Attachment.token/1)
        ExRatatui.textarea_insert_str(state.textarea, tokens)

        %{
          state
          | attachments: current ++ attachments,
            focus: :composer,
            notice: "#{length(attachments)} file(s) attached · F7 view/edit"
        }
    end
  end

  @doc "Freeze the current draft, reading edited files only when submitting."
  def prepare(state, text) do
    attachments = active(state)

    if attachments == [] do
      {:ok, text}
    else
      with {:ok, blocks} <- Alto.Result.traverse(attachments, &Attachment.content/1) do
        text =
          Enum.reduce(attachments, text, fn attachment, acc ->
            String.replace(acc, Attachment.token(attachment), "[Attached: #{attachment.name}]")
          end)

        content = Content.new([Content.text(text) | blocks])
        limit = Keyword.get(state.run_options, :max_transcript_bytes, 8_000_000)
        with {:ok, _} <- Content.normalize(content, limit), do: {:ok, content}
      end
    end
  end

  def message_options(%Content{} = content), do: [text: summary(content), content: content.blocks]
  def message_options(text), do: [text: text]

  @doc "Reject unsupported input before a run takes ownership of the draft."
  def validate_provider(%Content{} = content, {:codex, opts}),
    do: Alto.Contrib.Codex.Backend.check_input(content, opts)

  def validate_provider(%Content{} = content, {module, opts})
      when module in [Alto.Contrib.Providers.OpenAICompatible, Alto.Contrib.Providers.Anthropic],
      do: module.check_input(content, opts)

  def validate_provider(%Content{} = content, {module, opts}),
    do:
      Alto.InputModalities.check_request(
        %{messages: [%{"content" => content.blocks}]},
        module,
        opts
      )

  def validate_provider(%Content{} = content, nil),
    do: Alto.InputModalities.check_content(content, [])

  def validate_provider(_, _), do: :ok

  def summary(%Content{blocks: [first | rest]}) do
    Content.text_value([first]) <>
      Enum.map_join(rest, "", fn
        %{"type" => "text"} -> ""
        block -> "\n" <> Content.text_value([block])
      end)
  end

  def summary(text), do: Content.text_value(text)

  def open(state) do
    items =
      [%{label: "Attach a file…", action: &open_upload/1}] ++
        Enum.flat_map(active(state), fn attachment ->
          [
            %{
              label:
                "#{attachment.name} · #{attachment.size} bytes · #{if(attachment.editable?, do: "edit", else: "details")}",
              action: &edit(&1, attachment)
            },
            %{label: "Remove #{attachment.name}", action: &remove(&1, attachment)}
          ]
        end)

    %{state | overlay: Menu.new(:attachments, "attachments", items), leader?: false}
  end

  def open_upload(state) do
    menu =
      Menu.form(:attachment_upload, "attach a file", [{:path, "Path", "", []}],
        buttons: ["[ Attach ]", "[ Cancel ]"],
        on_action: &upload_action/2,
        hint: "Enter attach · Esc cancel",
        intro: "Local file path · images, text, PDFs and binary files"
      )

    %{state | overlay: menu, leader?: false}
  end

  def upload_action(state, :cancel), do: open(state)

  def upload_action(state, :submit) do
    next = upload(state, Menu.value(state.overlay, :path))

    if next.attachments == state.attachments,
      do: %{next | overlay: Map.put(state.overlay, :error, next.notice)},
      else: %{next | overlay: nil}
  end

  def edit(state, %{editable?: true} = attachment) do
    case Attachment.read(attachment) do
      {:ok, text} ->
        textarea = ExRatatui.textarea_new()
        ExRatatui.textarea_set_value(textarea, text)

        %{
          state
          | overlay: %{
              kind: :attachment_editor,
              title: attachment.name,
              textarea: textarea,
              attachment: attachment,
              error: nil
            }
        }

      {:error, reason} ->
        error(state, reason)
    end
  end

  def edit(state, attachment) do
    menu =
      Menu.new(:attachment_details, attachment.name, [
        %{
          label: "Copy file path",
          action: fn next ->
            result = next.clipboard_write.(attachment.path)
            %{next | clipboard_text: attachment.path, notice: Alto.TUI.Clipboard.notice(result)}
          end
        },
        %{label: "Back", action: &open/1}
      ])

    %{
      state
      | overlay:
          Map.put(
            menu,
            :intro,
            "#{attachment.media_type}\n#{attachment.size} bytes\n#{attachment.path}"
          )
    }
  end

  def remove(state, attachment) do
    draft = ExRatatui.textarea_get_value(state.textarea)

    ExRatatui.textarea_set_value(
      state.textarea,
      String.replace(draft, Attachment.token(attachment), "")
    )

    open(%{state | attachments: Enum.reject(state.attachments, &(&1.id == attachment.id))})
  end

  def editor_key(state, %Key{code: "esc"}), do: open(state)

  def editor_key(state, %Key{code: "s", modifiers: ["ctrl"]}) do
    editor = state.overlay

    case Attachment.update(editor.attachment, ExRatatui.textarea_get_value(editor.textarea)) do
      {:ok, attachment} ->
        state = %{
          state
          | attachments:
              Enum.map(state.attachments, fn item ->
                if item.id == attachment.id, do: attachment, else: item
              end),
            notice: "Saved #{attachment.name}"
        }

        open(state)

      {:error, reason} ->
        %{state | overlay: %{editor | error: Alto.Contrib.Display.error(reason)}}
    end
  end

  def editor_key(state, key) do
    ExRatatui.textarea_handle_key(state.overlay.textarea, key.code, key.modifiers)
    state
  end

  def editor_paste(state, text) do
    if String.valid?(text) and
         byte_size(text) + byte_size(ExRatatui.textarea_get_value(state.overlay.textarea)) <=
           6_000_000 do
      ExRatatui.textarea_insert_str(state.overlay.textarea, text)
      state
    else
      %{state | overlay: %{state.overlay | error: "Paste exceeds the attachment limit"}}
    end
  end

  @doc "Save media outputs and append readable paths to the transcript."
  def outputs(state, task_id, value) do
    case Attachment.materialize(value, options(state)) do
      {:ok, []} ->
        state

      {:ok, attachments} ->
        Enum.reduce(attachments, state, fn attachment, acc ->
          State.append_entry(acc, task_id, %{
            kind: :system,
            text: "Output: #{attachment.name}\n#{attachment.path}"
          })
        end)

      {:error, reason} ->
        error(state, {:output_save_failed, reason})
    end
  end

  defp error(state, reason),
    do: %{state | notice: Alto.Contrib.Display.error(reason) <> " · draft kept"}
end
