defmodule Alto.Tools.PublishFile do
  @moduledoc "Return a generated workspace file as a named downloadable output."
  use Alto.Tool, name: :publish_file, execution_mode: :parallel, approval: :never, arguments: true

  def options, do: %{max_bytes: 6_000_000}

  def arguments(_opts),
    do:
      {"Publish an existing workspace file (image, PDF, document, spreadsheet, audio, etc.) as an output attachment. Create the file with the available tools first.",
       [path: [type: :string, required: true]]}

  def run(arguments, context, opts) do
    with {:ok, path} <- Alto.Tools.Path.resolve(arguments["path"], context.cwd),
         {:ok, bytes} <- Alto.Attachment.read(path, opts.max_bytes) do
      name = Path.basename(path)
      media = Alto.Attachment.media_type(bytes, name)
      block = Alto.Content.artifact(name, media, Base.encode64(bytes))
      {:ok, Alto.Content.new([Alto.Content.text("Generated file: #{name}"), block])}
    end
  end
end
