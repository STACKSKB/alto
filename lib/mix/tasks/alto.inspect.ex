defmodule Mix.Tasks.Alto.Inspect do
  use Mix.Task
  @shortdoc "Inspect a trusted Alto configuration without starting a run"
  @moduledoc "Run `mix alto.inspect --config path/to/config.exs`. Configuration is trusted Elixir code. No credentials or provider options are printed."

  @impl true
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: [config: :string])
    if rest != [] or invalid != [], do: Mix.raise("usage: mix alto.inspect --config PATH")
    path = Keyword.get(opts, :config, Alto.Config.default_path())

    case Alto.Config.load(path) do
      {:ok, config} ->
        config |> Alto.Capabilities.describe() |> JSON.encode!() |> Mix.shell().info()

      {:error, reason} ->
        Mix.raise("Cannot load configuration: #{inspect(reason)}")
    end
  end
end
