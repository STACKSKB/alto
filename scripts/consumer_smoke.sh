#!/usr/bin/env bash
set -euo pipefail

package_tar=${1:?usage: consumer_smoke.sh path/to/alto-*.tar}
consumer_dir=$(mktemp -d)
trap 'rm -rf "$consumer_dir"' EXIT

mkdir "$consumer_dir/pkg"
tar -xf "$package_tar" -C "$consumer_dir/pkg"
tar -xzf "$consumer_dir/pkg/contents.tar.gz" -C "$consumer_dir/pkg"

cat > "$consumer_dir/mix.exs" <<'EOF'
defmodule ConsumerSmoke.MixProject do
  use Mix.Project

  def project do
    [app: :consumer_smoke, version: "0.0.0", elixir: "~> 1.18", deps: [{:alto, path: "pkg"}]]
  end
end
EOF

(cd "$consumer_dir" && MIX_ENV=prod mix deps.get --only prod --no-archives)
(cd "$consumer_dir" && MIX_ENV=prod mix run --no-start -e '
  unless Code.ensure_loaded?(Alto.TUI) or Code.ensure_loaded?(ExRatatui) do
    {:ok, _apps} = Application.ensure_all_started(:alto)

    defmodule ConsumerSmoke.Echo do
      @behaviour Alto.Tool
      def name, do: :echo
      def schema, do: %{parameters: %{type: "object", properties: %{}}}
      def execution_mode, do: :parallel
      def approval, do: :never
      def run(arguments, _context), do: {:ok, arguments}
    end

    {:ok, result} =
      Alto.run(%{"message" => "consumer"},
        loop: Alto.rule_loop(steps: ["echo"]),
        tools: [ConsumerSmoke.Echo]
      )

    unless result.model_requests == 0 and result.output == [%{"message" => "consumer"}] do
      raise "providerless rule smoke returned an unexpected result: #{inspect(result)}"
    end
  else
    raise "optional TUI dependency leaked into the production consumer"
  end
')
