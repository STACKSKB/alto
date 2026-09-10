defmodule AltoObanExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :alto_oban_example,
      version: "0.0.1",
      elixir: "~> 1.18",
      elixirc_paths: ["lib"],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AltoObanExample.Application, []}
    ]
  end

  defp deps do
    [
      {:alto, path: "../.."},
      {:ecto_sql, "~> 3.14"},
      {:oban, "~> 2.24"},
      {:postgrex, "~> 0.22"}
    ]
  end
end
