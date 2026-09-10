defmodule Mix.Tasks.Alto.Operations do
  use Mix.Task
  @shortdoc "Inspect or reconcile a stopped application's operation ledger"
  @moduledoc """
  Stop the application that owns the ledger before opening it here.

      mix alto.operations --id maintenance --dir /state/ledgers list
      mix alto.operations --id maintenance --dir /state/ledgers show OPERATION_KEY
      mix alto.operations --id maintenance --dir /state/ledgers reconcile OPERATION_KEY --revision 3 --resolution confirmed_committed --evidence '{"note":"Verified artifact checksum"}'

  Resolutions are `confirmed_committed`, `confirmed_failed`, or `retry_permitted`.
  Reconciliation records evidence with a revision check. Permitting a retry
  does not execute or enqueue it; use the application's recovery flow afterward.
  """
  @resolutions %{
    "confirmed_committed" => :confirmed_committed,
    "confirmed_failed" => :confirmed_failed,
    "retry_permitted" => :retry_permitted
  }

  @impl true
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          id: :string,
          dir: :string,
          revision: :integer,
          resolution: :string,
          evidence: :string
        ]
      )

    if invalid != [] or not is_binary(opts[:id]),
      do: Mix.raise("--id is required; see mix help alto.operations")

    Mix.Task.run("app.start")

    case Alto.OperationLog.start_link(Keyword.take(opts, [:id, :dir]) ++ [name: nil]) do
      {:ok, ledger} ->
        try do
          execute(ledger, args, opts)
          |> inspect(pretty: true, limit: :infinity)
          |> Mix.shell().info()
        after
          GenServer.stop(ledger)
        end

      {:error, reason} ->
        Mix.raise("Cannot open ledger: #{inspect(reason)}")
    end
  end

  defp execute(ledger, ["list"], _opts) do
    keys = Enum.uniq(Alto.OperationLog.list_open(ledger) ++ Alto.OperationLog.list_parked(ledger))

    Enum.map(keys, fn key ->
      %{
        key: key,
        status: Alto.OperationLog.status(ledger, key),
        recovery: Alto.OperationLog.recovery(ledger, key)
      }
    end)
  end

  defp execute(ledger, ["show", key], _opts), do: Alto.OperationLog.recovery(ledger, key)

  defp execute(ledger, ["reconcile", key], opts) do
    with revision when is_integer(revision) and revision > 0 <- opts[:revision],
         {:ok, resolution} <- Map.fetch(@resolutions, opts[:resolution]),
         {:ok, evidence} when is_map(evidence) and map_size(evidence) > 0 <-
           JSON.decode(opts[:evidence] || "null") do
      Alto.OperationLog.reconcile(ledger, key, revision, resolution, evidence)
    else
      _ ->
        Mix.raise(
          "Reconciliation requires --revision, --resolution, and a nonempty JSON --evidence object"
        )
    end
  end

  defp execute(_, _, _),
    do: Mix.raise("Expected list, show KEY, or reconcile KEY; see mix help alto.operations")
end
