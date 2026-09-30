defmodule Alto.Attachment do
  @moduledoc """
  Private file staging shared by interactive uploads and generated outputs.

  Attachment records contain paths and metadata, never a retained copy of the
  bytes. `content/1` reads a bounded snapshot at submission time. Persisted typed
  content is self-contained and does not depend on the staging file surviving.
  Hosts own retention of the staging directory.
  """
  alias Alto.{AtomicFile, BoundedFile, Content}

  @enforce_keys [:id, :path, :name, :media_type, :size, :editable?]
  defstruct [:id, :path, :name, :media_type, :size, :editable?]

  @max_bytes 6_000_000
  @limits %{max_dimension: 16_384, max_pixels: 40_000_000}
  @types %{
    ".pdf" => "application/pdf",
    ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ".zip" => "application/zip",
    ".mp3" => "audio/mpeg",
    ".wav" => "audio/wav",
    ".mp4" => "video/mp4",
    ".webm" => "video/webm",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  def directory, do: Path.join(Path.dirname(Alto.Session.dir()), "attachments")
  def token(attachment), do: "[#{attachment.name}##{String.slice(attachment.id, 0, 8)}]"

  @doc "Copy a selected local file into private staging; the original is never edited."
  def upload(path, opts \\ []) do
    with {:ok, data} <- read(path, Keyword.get(opts, :max_bytes, @max_bytes)),
         do: stage(data, Path.basename(path), opts)
  end

  @doc "Stage pasted bytes or an output, with a random identity and a stable path."
  def stage(data, name, opts \\ []) when is_binary(data) do
    media = Keyword.get(opts, :media_type) || media_type(data, name)

    id =
      Keyword.get_lazy(opts, :id, fn ->
        Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      end)

    root = Keyword.get(opts, :directory, directory()) |> Path.expand()
    name = safe_name(name)
    path = Path.join([root, id, name])

    with true <-
           (is_binary(id) and Regex.match?(~r/^[a-zA-Z0-9_-]{1,64}$/, id)) or
             {:error, :invalid_attachment_id},
         true <-
           byte_size(data) <= Keyword.get(opts, :max_bytes, @max_bytes) or
             {:error, :attachment_too_large},
         {:ok, _block} <- block(data, name, media),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(root, 0o700),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- AtomicFile.write(path, data, mode: 0o600) do
      {:ok,
       %__MODULE__{
         id: id,
         path: path,
         name: name,
         media_type: media,
         size: byte_size(data),
         editable?: media == "text/plain"
       }}
    end
  end

  @doc "Replace a text paste in the same file; queued content snapshots stay unchanged."
  def update(%__MODULE__{editable?: true} = attachment, text) when is_binary(text) do
    with true <-
           (String.valid?(text) and byte_size(text) <= @max_bytes) or
             {:error, :invalid_attachment_text},
         :ok <- AtomicFile.write(attachment.path, text, mode: 0o600),
         do: {:ok, %{attachment | size: byte_size(text)}}
  end

  def update(_, _), do: {:error, :attachment_not_editable}

  def read(%__MODULE__{path: path}), do: read(path, @max_bytes)

  def read(path, limit) do
    case BoundedFile.snapshot(path, limit) do
      {:ok, %{content: bytes}} when is_binary(bytes) -> {:ok, bytes}
      {:ok, _} -> {:error, :attachment_too_large}
      error -> error
    end
  end

  @doc "Read the current file into a validated provider-neutral block."
  def content(%__MODULE__{} = attachment) do
    with {:ok, data} <- read(attachment), do: block(data, attachment.name, attachment.media_type)
  end

  @doc "Materialize image and file output blocks as private, named files."
  def materialize(value, opts \\ []) do
    blocks = if match?(%Content{}, value), do: value.blocks, else: value

    with {:ok, content} <- Content.decode_transcript(blocks) do
      content.blocks
      |> Enum.reject(&(&1["type"] == "text"))
      |> Alto.Result.traverse(fn block ->
        {:ok, bytes} = Base.decode64(block["data"])
        name = block["name"] || "image" <> extension(block["media_type"])

        id =
          :crypto.hash(:sha256, [name, block["media_type"], bytes]) |> Base.encode16(case: :lower)

        stage(
          bytes,
          name,
          opts |> Keyword.put(:media_type, block["media_type"]) |> Keyword.put(:id, id)
        )
      end)
    else
      :not_content -> {:ok, []}
      error -> error
    end
  end

  @doc "Split a large UTF-8 paste into bounded files, preserving every byte and order."
  def paste(text, opts \\ []) do
    limit = Keyword.get(opts, :chunk_bytes, 32_000)

    with true <-
           (String.valid?(text) and byte_size(text) <= Keyword.get(opts, :max_bytes, @max_bytes)) or
             {:error, :paste_too_large},
         true <- (is_integer(limit) and limit >= 4) or {:error, :invalid_chunk_size} do
      text
      |> chunks(limit, [])
      |> Enum.with_index(1)
      |> Alto.Result.traverse(fn {chunk, index} -> stage(chunk, "paste-#{index}.txt", opts) end)
    end
  end

  defp chunks("", _limit, acc), do: Enum.reverse(acc)
  defp chunks(text, limit, acc) when byte_size(text) <= limit, do: Enum.reverse([text | acc])

  defp chunks(text, limit, acc) do
    size = utf8_boundary(text, limit)
    prefix = binary_part(text, 0, size)
    # Prefer a line boundary when it does not produce very small chunks.
    size =
      case :binary.matches(prefix, "\n") |> List.last() do
        {position, 1} when position >= div(limit, 2) -> position + 1
        _ -> size
      end

    <<part::binary-size(size), rest::binary>> = text
    chunks(rest, limit, [part | acc])
  end

  defp utf8_boundary(text, size) do
    if Bitwise.band(:binary.at(text, size), 0xC0) == 0x80,
      do: utf8_boundary(text, size - 1),
      else: size
  end

  defp block(data, name, "text/plain") do
    if String.valid?(data),
      do: {:ok, Content.text("Attached file: #{name}\n" <> data)},
      else: {:error, :attachment_must_be_utf8}
  end

  defp block(data, _name, media) when media in ["image/png", "image/jpeg"] do
    with {:ok, actual, width, height} <- Alto.Image.Metadata.inspect(data, @limits),
         true <- actual == media or {:error, :image_metadata_mismatch},
         do: {:ok, Content.image(media, Base.encode64(data), width, height)}
  end

  defp block(data, name, media) do
    block = Content.file(name, media, Base.encode64(data))
    with {:ok, _} <- Content.decode_transcript([block]), do: {:ok, block}
  end

  def media_type(<<0x89, "PNG", _::binary>>, _), do: "image/png"
  def media_type(<<0xFF, 0xD8, _::binary>>, _), do: "image/jpeg"
  def media_type(<<"%PDF-", _::binary>>, _), do: "application/pdf"

  def media_type(data, name),
    do:
      Map.get(@types, String.downcase(Path.extname(name))) ||
        if(String.valid?(data) and not String.contains?(data, <<0>>),
          do: "text/plain",
          else: "application/octet-stream"
        )

  defp extension("image/png"), do: ".png"
  defp extension("image/jpeg"), do: ".jpg"
  defp extension(_), do: ".bin"

  defp safe_name(name),
    do:
      name
      |> Path.basename()
      |> String.replace(~r/[\x00-\x1F\\]/u, "_")
      |> Alto.Text.truncate(240, "")
      |> then(fn name -> if name in ["", ".", ".."], do: "attachment", else: name end)
end
