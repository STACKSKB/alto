defmodule Mix.Tasks.Alto do
  use Mix.Task

  @shortdoc "Run Alto's serial coding-agent loop"

  @impl Mix.Task
  def run(argv) do
    case Alto.CLI.run(argv) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
