defmodule Mix.Tasks.Alto.Session.Export do
  use Mix.Task
  @shortdoc "Export a session's records and resumable transcript as JSON"
  @moduledoc """
      mix alto.session.export SESSION_ID --session-dir /state/sessions --output session.json

  Without `--output`, prints JSON to stdout. Stop active writers when a single
  consistent checkpoint is needed. Native values remain in their exact tagged
  envelopes. Exported conversations and tool results may contain sensitive
  content; output files are private and atomically replaced.
  """

  @impl true
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [session_dir: :string, output: :string])

    if invalid != [] or length(args) != 1,
      do: Mix.raise("Expected SESSION_ID, optional --session-dir and --output")

    [id] = args
    storage = Keyword.take(opts, [:session_dir])

    with {:ok, records} <- Alto.Session.read(id, storage),
         {:ok, transcript} <- snapshot(id, storage) do
      content =
        JSON.encode!(%{version: 1, session_id: id, records: records, transcript: transcript}) <>
          "\n"

      case opts[:output] do
        nil ->
          IO.write(content)

        path ->
          case Alto.Tools.AtomicWrite.write(Path.expand(path), content, 0o600) do
            :ok -> Mix.shell().info("Exported #{id} to #{Path.expand(path)}")
            {:error, reason} -> Mix.raise("Export failed: #{inspect(reason)}")
          end
      end
    else
      {:error, reason} -> Mix.raise("Cannot export session: #{inspect(reason)}")
    end
  end

  defp snapshot(id, opts) do
    case Alto.Session.transcript(id, opts) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, :no_resumable_transcript} -> {:ok, nil}
      error -> error
    end
  end
end
