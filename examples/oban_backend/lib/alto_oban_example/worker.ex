defmodule AltoObanExample.Worker do
  use Oban.Worker, queue: :alto, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run" => run, "payload" => %{"body" => body}}}) do
    with {:ok, run_options} <- AltoObanExample.Runs.fetch(run),
         %Alto.Runner.Result{status: :ok} <- Alto.Contrib.run(body, run_options) do
      :ok
    else
      %Alto.Runner.Result{verdict: :unknown} ->
        {:discard, "unknown outcome; reconcile the operation before restoring work"}

      %Alto.Runner.Result{reason: reason} ->
        {:error, inspect(reason)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
