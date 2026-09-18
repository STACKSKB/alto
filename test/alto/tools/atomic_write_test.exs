defmodule Alto.Tools.AtomicWriteTest do
  use ExUnit.Case, async: false

  alias Alto.Tools.AtomicWrite

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-atomic-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    original_path = System.get_env("PATH")

    on_exit(fn ->
      File.rm_rf!(dir)
      restore_path(original_path)
    end)

    %{dir: dir}
  end

  test "writes, renames, and leaves no temporary sibling", %{dir: dir} do
    path = Path.join(dir, "state.txt")
    assert :ok = AtomicWrite.write(path, "new")
    assert File.read!(path) == "new"
    assert Path.wildcard(Path.join(dir, ".state.txt.alto-*.tmp")) == []
  end

  test "reports post-rename directory sync failure as uncertain", %{dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir!(bin)
    sync = Path.join(bin, "sync")
    File.write!(sync, "#!/bin/sh\nexit 42\n")
    File.chmod!(sync, 0o755)
    System.put_env("PATH", bin <> ":" <> (System.get_env("PATH") || ""))

    path = Path.join(dir, "state.txt")

    assert {:error, {:post_rename_sync_failed, {:directory_sync_failed, 42, _}}} =
             AtomicWrite.write(path, "published")

    assert File.read!(path) == "published"
    assert Path.wildcard(Path.join(dir, ".state.txt.alto-*.tmp")) == []
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end
