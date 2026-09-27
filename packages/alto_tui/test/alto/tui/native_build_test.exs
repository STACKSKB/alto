defmodule Alto.TUI.NativeBuildTest do
  use ExUnit.Case, async: false

  test "reinstalling a cached NIF preserves files already opened by a running VM" do
    root = Path.join(System.tmp_dir!(), "alto-nif-#{System.unique_integer([:positive])}")
    app = Path.join(root, "alto_nif_fixture")
    ebin = Path.join(app, "ebin")
    native = Path.join(app, "priv/native")
    File.mkdir_p!(ebin)
    File.mkdir_p!(native)
    Code.prepend_path(ebin)

    on_exit(fn ->
      Code.delete_path(ebin)
      File.rm_rf!(root)
    end)

    filename = "libfixture.so"
    target = Path.join(native, filename)
    archive = Path.join(root, filename <> ".tar.gz")
    replacement = :binary.copy("new native code", 1024)
    File.write!(target, "running native code")
    {:ok, running} = File.open(target, [:read, :binary])
    on_exit(fn -> File.close(running) end)

    :ok =
      :erl_tar.create(
        String.to_charlist(archive),
        [{String.to_charlist(filename), replacement}],
        [:compressed]
      )

    checksum = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)

    File.write!(
      Path.join(root, "checksum-Elixir.AltoNativeFixture.exs"),
      inspect(%{Path.basename(archive) => "sha256:" <> checksum})
    )

    config = %RustlerPrecompiled.Config{otp_app: :alto_nif_fixture, module: AltoNativeFixture}

    metadata = %{
      lib_name: "libfixture",
      file_name: Path.basename(archive),
      cached_tar_gz: archive
    }

    File.cd!(root, fn ->
      for _ <- 1..3 do
        assert {:ok, _} = RustlerPrecompiled.download_or_reuse_nif_file(config, metadata)
        assert File.read!(target) == replacement
        assert File.ls!(native) == [filename]
      end
    end)

    # Overwriting the old inode changes this descriptor too and can SIGBUS a
    # process mapping it. Renaming leaves that running process's bytes intact.
    assert IO.binread(running, :eof) == "running native code"
  end
end
