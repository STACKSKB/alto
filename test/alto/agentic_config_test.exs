defmodule Alto.AgenticConfigTest do
  use ExUnit.Case, async: false

  setup do
    diagnostics = System.get_env("ALTO_REQUEST_DIAGNOSTICS")
    System.delete_env("ALTO_REQUEST_DIAGNOSTICS")

    on_exit(fn ->
      if diagnostics,
        do: System.put_env("ALTO_REQUEST_DIAGNOSTICS", diagnostics),
        else: System.delete_env("ALTO_REQUEST_DIAGNOSTICS")
    end)
  end

  test "request diagnostics are explicitly enabled" do
    System.put_env("ALTO_REQUEST_DIAGNOSTICS", "1")
    assert {:ok, config} = Alto.Config.load(Path.expand("../../alto.agentic.exs", __DIR__))
    assert [profile] = Alto.Config.run_options(config)[:provider_profiles]
    assert {Alto.Providers.Observe, _} = profile[:provider]
  end

  test "the coding profile loads as Alto configuration" do
    path = Path.expand("../../alto.agentic.exs", __DIR__)
    assert {:ok, %Alto.Config{}} = Alto.Config.load(path)
  end
end
