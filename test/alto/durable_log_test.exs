defmodule Alto.DurableLogTest do
  use ExUnit.Case, async: true

  alias Alto.DurableLog

  test "interruption before repair rename preserves the authoritative file" do
    dir = Path.join(System.tmp_dir!(), "alto-repair-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "state.jsonl")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    File.write!(path, "acknowledged\n")

    assert {:error, :injected_interrupt} =
             DurableLog.replace(path, "replacement\n",
               before_rename: fn -> {:error, :injected_interrupt} end
             )

    assert File.read!(path) == "acknowledged\n"
    assert Path.wildcard(path <> ".repair-*") == []
  end

  test "repair atomically replaces the file and removes its temporary sibling" do
    dir = Path.join(System.tmp_dir!(), "alto-repair-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "state.jsonl")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    File.write!(path, "old\n")

    assert :ok = DurableLog.replace(path, ["new", "\n"])
    assert File.read!(path) == "new\n"
    assert Path.wildcard(path <> ".repair-*") == []
  end
end
