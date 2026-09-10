defmodule AltoObanExample.Worker do
  use Oban.Worker, queue: :alto, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run" => run, "payload" => %{"body" => body}}}) do
    with {:ok, run_options} <- AltoObanExample.Runs.fetch(run),
         {:ok, _result} <- Alto.run(body, run_options) do
      :ok
    else
      {:error, _reason, %{outcome: :unknown}} ->
        {:discard, "unknown outcome; reconcile the operation before restoring work"}

      {:error, reason, _result} ->
        {:error, inspect(reason)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
