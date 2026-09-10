defmodule Alto.MixProject do
  use Mix.Project

  def project do
    [
      app: :alto,
      version: "0.0.1",
      description: "A bounded, composable BEAM-native coding-agent harness",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Alto.CLI],
      package: package(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Alto.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      {:plug_crypto, "~> 2.2"},
      {:req, "~> 0.7.4"},
      {:thousand_island, "~> 1.5"},
      {:websock, "~> 0.5"},
      {:ex_ratatui, "~> 0.13.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Source" => "https://github.com/STACKSKB/alto"},
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "PROTOCOL.md",
        "docs/delayed-queue.md",
        "examples/README.md",
        "examples/repository_maintenance",
        "examples/document_intake"
      ]
    ]
  end

  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(_env), do: ["lib", "packages/alto_tui/lib"]
end
