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
      package: [
        licenses: ["MIT"],
        links: %{"Source" => "https://github.com/STACKSKB/alto"},
        files: ["lib", "deploy", "mix.exs", "README.md", "LICENSE"]
      ],
      releases: [
        alto: [
          include_executables_for: [:unix],
          include_src: false,
          steps: [:assemble, &package_service/1, :tar]
        ]
      ],
      deps: deps()
    ]
  end

  defp package_service(release) do
    sources = [
      {"deploy", "deploy"},
      {"../../examples/resident", "examples/resident"},
      {"../../docs/resident-service.md", "docs/resident-service.md"}
    ]

    paths =
      Enum.flat_map(sources, fn {source, destination} ->
        if File.exists?(source) do
          target = Path.join(release.path, destination)
          File.mkdir_p!(Path.dirname(target))

          source
          |> File.cp_r!(target)
          |> Enum.filter(&File.regular?/1)
          |> Enum.map(&Path.relative_to(&1, release.path))
        else
          []
        end
      end)

    %{release | overlays: release.overlays ++ paths}
  end

  def application,
    do: [extra_applications: [:logger, :crypto], mod: {Alto.Contrib.Application, []}]

  defp deps do
    root = Path.expand("../..", __DIR__)

    checkout? =
      __DIR__ == Path.join([root, "packages", "alto_contrib"]) and
        File.exists?(Path.join(root, "lib/alto.ex"))

    alto =
      if System.get_env("ALTO_HEX_BUILD") != "1" and checkout?,
        do: {:alto, path: root},
        else: {:alto, "~> 0.0.2"}

    [
      alto,
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.7.4"},
      {:server_sent_events, "~> 1.1"},
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      {:plug_crypto, "~> 2.2"},
      {:thousand_island, "~> 1.5"},
      {:websock, "~> 0.5"}
    ]
  end
end
