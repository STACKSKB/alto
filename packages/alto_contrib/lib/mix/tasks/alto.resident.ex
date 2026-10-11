defmodule Mix.Tasks.Alto.Resident do
  @shortdoc "Inspect and control an Alto resident service"
  use Mix.Task

  def run(args) do
    Mix.Task.run("app.start")

    case Alto.Contrib.Resident.CLI.run(args) do
      :ok -> :ok
      {:error, reason} -> Mix.raise(inspect(reason))
    end
  end
end
