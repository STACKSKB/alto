defmodule AltoTUI.MixProject do
  use Mix.Project

  def project do
    alto_dep =
      if System.get_env("ALTO_TUI_LOCAL"),
        do: {:alto, path: "../.."},
        else: {:alto, "~> 0.0.1"}

    [
      app: :alto_tui,
      version: "0.0.1",
      description: "Optional terminal UI for Alto",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      package: [
        licenses: ["MIT"],
        links: %{"Source" => "https://github.com/STACKSKB/alto/tree/v0.0.1/packages/alto_tui"},
        files: ["lib", "mix.exs", "README.md", "LICENSE"]
      ],
      deps: [alto_dep, {:ex_ratatui, "~> 0.13.1"}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
