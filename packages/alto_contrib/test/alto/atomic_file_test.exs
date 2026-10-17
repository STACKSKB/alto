defmodule Alto.AtomicFileTest do
  use ExUnit.Case, async: false

  alias Alto.AtomicFile

  @moduletag :tmp_dir
  setup do
    original_path = System.get_env("PATH")
    on_exit(fn -> restore_path(original_path) end)
  end

  test "reports post-rename directory sync failure as uncertain", %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir!(bin)
    sync = Path.join(bin, "sync")
    File.write!(sync, "#!/bin/sh\nexit 42\n")
    File.chmod!(sync, 0o755)
    System.put_env("PATH", bin <> ":" <> (System.get_env("PATH") || ""))

    path = Path.join(dir, "state.txt")

    assert {:error, {:post_rename_sync_failed, {:directory_sync_failed, 42, _}}} =
             AtomicFile.write(path, "published")

    assert File.read!(path) == "published"
    assert Path.wildcard(Path.join(dir, ".state.txt.alto-*.tmp")) == []

    context = %{session_id: "test", cwd: dir}

    for {tool, arguments, expected} <- [
          {Alto.Contrib.Tools.WriteFile, %{"path" => "state.txt", "content" => "written"},
           "written"},
          {Alto.Contrib.Tools.EditFile,
           %{
             "path" => "state.txt",
             "edits" => [%{"old_text" => "written", "new_text" => "edited"}]
           }, "edited"}
        ] do
      assert {:ok, prepared, _details} = Alto.Tool.prepare(tool, arguments, context, [])
      assert {:unknown, {:directory_sync_failed, 42, _}} = tool.run(prepared, context)
      assert File.read!(path) == expected
      assert Path.wildcard(Path.join(dir, ".state.txt.alto-*.tmp")) == []
    end
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end
