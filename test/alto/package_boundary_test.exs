defmodule Alto.PackageBoundaryTest do
  use ExUnit.Case, async: true

  test "the installed core application depends only on OTP, Elixir and its option validator" do
    assert {:ok, applications} = :application.get_key(:alto, :applications)

    assert Enum.sort(applications) ==
             Enum.sort([:kernel, :stdlib, :elixir, :logger, :crypto, :nimble_options])
  end

  test "compiled core modules cannot import optional Alto implementations" do
    assert {:ok, modules} = :application.get_key(:alto, :modules)
    core = MapSet.new(modules)

    for module <- modules do
      refute String.starts_with?(Atom.to_string(module), [
               "Elixir.Alto.Contrib",
               "Elixir.Alto.TUI"
             ])

      assert {:ok, {^module, [imports: imports]}} =
               :beam_lib.chunks(:code.which(module), [:imports])

      for {target, _function, _arity} <- imports,
          String.starts_with?(Atom.to_string(target), "Elixir.Alto.") do
        assert MapSet.member?(core, target),
               "#{inspect(module)} imports #{inspect(target)} outside the core application"
      end
    end
  end
end
