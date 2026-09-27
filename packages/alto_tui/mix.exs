defmodule AltoTUI.MixProject do
  use Mix.Project

  def project do
    alto_path = Path.expand("../..", __DIR__)

    alto_dep =
      if File.exists?(Path.join(alto_path, "mix.exs")) do
        {:alto, path: alto_path}
      else
        {:alto, "~> 0.0.2"}
      end

    [
      app: :alto_tui,
      version: "0.0.2",
      description: "Optional terminal UI for Alto",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      package: [
        licenses: ["MIT"],
        links: %{"Source" => "https://github.com/STACKSKB/alto/tree/v0.0.2/packages/alto_tui"},
        files: ["lib", "build", "mix.exs", "README.md", "LICENSE"]
      ],
      deps: [
        alto_dep,
        {:ex_ratatui, "~> 0.13.1"},
        # Patch the existing transitive dependency until upstream extracts NIFs atomically.
        {:rustler_precompiled, "== 0.9.0",
         override: true,
         compile:
           "elixir " <>
             shell_quote(Path.join(__DIR__, "build/rustler_precompiled.exs")) <> " --compile"}
      ],
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"])
    ]
  end

  defp shell_quote(path) do
    case :os.type() do
      {:win32, _} -> "\"" <> path <> "\""
      _ -> "'" <> String.replace(path, "'", "'\\''") <> "'"
    end
  end

  def application do
    [extra_applications: [:logger]]
  end
end
