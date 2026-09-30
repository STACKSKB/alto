defmodule Mix.Tasks.Alto.Session.Compact do
  use Mix.Task
  @shortdoc "Convert a session's retained conversations to incremental storage"
  @moduledoc """
      mix alto.session.compact SESSION_ID --session-dir /state/sessions
      mix alto.session.compact SESSION_ID --retained-turns 20

  Keeps all turns by default. Revisions, current context, and dispatch fences
  survive conversion. A finite retained-turns policy removes older rewind points.
  """
  @impl true
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [session_dir: :string, retained_turns: :integer])

    if invalid != [] or length(args) != 1,
      do: Mix.raise("Expected SESSION_ID, optional --session-dir and --retained-turns")

    [id] = args

    storage =
      Keyword.take(opts, [:session_dir])
      |> Keyword.put(:conversation_retained_turns, Keyword.get(opts, :retained_turns, :infinity))

    case Alto.Session.Conversation.compact(id, storage) do
      {:ok, record} ->
        Mix.shell().info(
          "Compacted #{id}: revision #{record["revision"]}, #{record["conversation_bytes"]} retained bytes"
        )

      {:error, reason} ->
        Mix.raise("Cannot compact session: #{inspect(reason)}")
    end
  end
end
