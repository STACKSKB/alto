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

    assert {:ok, published} =
             Handoff.persist("sess-test", "run-test", artifact, session_dir: root)

    assert File.read!(published.files.design) == "Keep effects host-owned.\n"
    assert File.read!(published.files.pointers) == "lib/alto/runner/serial.ex:1100\n"
    assert File.read!(published.files.handoff) == "The rollover contract is implemented.\n"
    assert File.read!(published.files.next_step) == "Run the focused rollover tests.\n"
  end

  test "rejects prose, incomplete objects, and oversized payloads" do
    assert {:error, {:handoff_invalid_json, _}} = Handoff.decode("a summary", 100)
    assert {:error, {:invalid_handoff_field, missing}} = Handoff.decode(~s({"design":"x"}), 100)
    assert missing in [:pointers, :handoff, :next_step]
    assert {:error, {:handoff_too_large, 20, 10}} = Handoff.decode(String.duplicate("x", 20), 10)
  end
end
