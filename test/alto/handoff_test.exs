defmodule Alto.HandoffTest do
  use ExUnit.Case, async: true

  alias Alto.Handoff

  setup do
    root = Path.join(System.tmp_dir!(), "alto-handoff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "decodes, renders, and atomically publishes structured handoffs", %{root: root} do
    payload =
      JSON.encode!(%{
        design: "Keep effects host-owned.",
        pointers: "lib/alto/runner/serial.ex:1100",
        handoff: "The rollover contract is implemented.",
        next_step: "Run the focused rollover tests."
      })

    assert {:ok, artifact} = Handoff.decode(payload, 1_000)

    assert Handoff.render(artifact) =~ "# Next step\nRun the focused rollover tests."

    results =
      1..2
      |> Task.async_stream(fn _ ->
        Handoff.persist("sess-test", "run-test", artifact, session_dir: root)
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, path}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:error, {:handoff_write_failed, :handoff_already_exists}} in results
    assert JSON.decode!(File.read!(path)) == JSON.decode!(payload)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "rejects prose, incomplete objects, and oversized payloads" do
    assert {:error, {:handoff_invalid_json, _}} = Handoff.decode("a summary", 100)
    assert {:error, {:invalid_handoff_field, missing}} = Handoff.decode(~s({"design":"x"}), 100)
    assert missing in [:pointers, :handoff, :next_step]
    assert {:error, {:handoff_too_large, 20, 10}} = Handoff.decode(String.duplicate("x", 20), 10)
  end
end
