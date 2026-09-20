defmodule AltoTUI.MixProject do
  use Mix.Project

  def project do
    alto_path = Path.expand("../..", __DIR__)

    alto_dep =
      if File.exists?(Path.join(alto_path, "mix.exs")) do
        {:alto, path: alto_path}
      else
        {:alto, "~> 0.0.1"}
      end

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
      deps: [alto_dep, {:ex_ratatui, "~> 0.13.1"}],
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"])
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
