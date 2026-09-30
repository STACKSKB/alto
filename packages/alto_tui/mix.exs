defmodule AltoTUI.MixProject do
  use Mix.Project

  def project do
    alto_path = Path.expand("../..", __DIR__)

    checkout? =
      __DIR__ == Path.join([alto_path, "packages", "alto_tui"]) and
        File.exists?(Path.join(alto_path, "lib/alto.ex")) and
        System.get_env("ALTO_HEX_BUILD") != "1"

    alto_dep =
      if checkout? do
        {:alto, path: alto_path}
      else
        {:alto, "~> 0.0.2"}
      end

    contrib_path = Path.expand("../alto_contrib", __DIR__)

    contrib_dep =
      if checkout? and File.exists?(Path.join(contrib_path, "mix.exs")),
        do: {:alto_contrib, path: contrib_path},
        else: {:alto_contrib, "~> 0.0.2"}

    [
      app: :alto_tui,
      version: "0.0.2",
      description: "Optional terminal UI for Alto",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      package: [
        licenses: ["MIT"],
        links: %{"Source" => "https://github.com/STACKSKB/alto"},
        files: ["lib", "build", "mix.exs", "README.md", "LICENSE"]
      ],
      deps: [
        alto_dep,
        contrib_dep,
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
