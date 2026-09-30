defmodule Alto.MixProject do
  use Mix.Project

  def project do
    [
      app: :alto,
      version: "0.0.2",
      description: "A bounded, composable BEAM-native coding-agent harness",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
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
      {:req, "~> 0.7.4"},
      {:nimble_options, "~> 1.1"},
      {:server_sent_events, "~> 1.1"}
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
        "docs/README.md",
        "docs/configuration.md",
        "docs/delayed-queue.md",
        "docs/checkpoints.md",
        "docs/parent-continuations.md",
        "docs/child-continuations.md",
        "docs/runners.md",
        "docs/loop-contract.md",
        "docs/subagents.md",
        "docs/context-reduction.md",
        "docs/tool-batches.md",
        "docs/interactive-input.md",
        "docs/conversations.md",
        "docs/extensions.md",
        "docs/sse-adapter.md",
        "docs/benchmarks.md",
        "bench/tool_batches.exs",
        "examples/README.md",
        "examples/repository_maintenance",
        "examples/document_intake"
      ]
    ]
  end

  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
