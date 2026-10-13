defmodule Alto.DurableLogTest do
  use ExUnit.Case, async: true

  alias Alto.DurableLog

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-repair-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "state.jsonl")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    %{path: path}
  end

  test "replay preserves failed decoding and repairs only a successfully decoded torn log", %{
    path: path
  } do
    decode = fn lines -> {:ok, lines} end
    assert {:ok, []} = DurableLog.replay(path, 100, [], decode)
    File.write!(path, "retained\npartial")

    assert {:error, :corrupt} =
             DurableLog.replay(path, 100, [], fn _ -> {:error, :corrupt} end)

    assert File.read!(path) == "retained\npartial"
    assert {:error, {:log_too_large, _, 5}} = DurableLog.replay(path, 5, [], decode)
    assert File.read!(path) == "retained\npartial"
    assert {:ok, ["retained"]} = DurableLog.replay(path, 100, [], decode)
    assert File.read!(path) == "retained\n"
  end

  test "interruption before repair rename preserves the authoritative file", %{path: path} do
    File.write!(path, "acknowledged\n")

    assert {:error, :injected_interrupt} =
             DurableLog.replace(path, "replacement\n",
               before_rename: fn -> {:error, :injected_interrupt} end
             )

    assert File.read!(path) == "acknowledged\n"
    assert Path.wildcard(Path.join(Path.dirname(path), ".state.jsonl.alto-*.tmp")) == []
  end

  test "repair atomically replaces the file and removes its temporary sibling", %{path: path} do
    File.write!(path, "old\n")
    File.chmod!(path, 0o640)

    assert :ok = DurableLog.replace(path, ["new", "\n"])
    assert File.read!(path) == "new\n"
    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o640
    assert Path.wildcard(Path.join(Path.dirname(path), ".state.jsonl.alto-*.tmp")) == []
  end
end
