defmodule AltoContrib.MixProject do
  use Mix.Project

  def project do
    [
      app: :alto_contrib,
      version: "0.0.2",
      description: "Optional applications and integrations for Alto",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths:
        if(Mix.env() == :test,
          do: ["lib", Path.expand("../../test/support", __DIR__)],
          else: ["lib"]
        ),
      escript: [name: "alto", main_module: Alto.Contrib.CLI],
      package: [licenses: ["MIT"], files: ["lib", "mix.exs", "README.md", "LICENSE"]],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    root = Path.expand("../..", __DIR__)

    alto =
      if File.exists?(Path.join(root, "mix.exs")),
        do: {:alto, path: root},
        else: {:alto, "~> 0.0.2"}

    [
      alto,
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      {:plug_crypto, "~> 2.2"},
      {:thousand_island, "~> 1.5"},
      {:websock, "~> 0.5"}
    ]
  end
end
