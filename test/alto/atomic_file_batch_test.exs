defmodule Alto.AtomicFileBatchTest do
  use ExUnit.Case, async: true
  import Bitwise

  @tag :tmp_dir
  test "independent synced objects preserve private permissions and an error leaves only a published prefix",
       %{tmp_dir: dir} do
    one = Path.join(dir, "one")
    two = Path.join(dir, "two")

    assert :ok =
             Alto.AtomicFile.write_many([
               {one, "one", [mode: 0o600]},
               {two, "old", [mode: 0o600]}
             ])

    assert File.read!(one) == "one"
    assert (File.stat!(one).mode &&& 0o777) == 0o600

    assert {:error, :injected} =
             Alto.AtomicFile.write_many([
               {one, "new", [mode: 0o600]},
               {two, "new", [mode: 0o600, before_rename: fn -> {:error, :injected} end]},
               {Path.join(dir, "must-not-write"), "later", [mode: 0o600]}
             ])

    assert File.read!(one) == "new"
    assert File.read!(two) == "old"
    assert Enum.sort(File.ls!(dir)) == ["one", "two"]
  end
end
