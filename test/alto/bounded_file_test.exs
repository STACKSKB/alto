defmodule Alto.BoundedFileTest do
  use ExUnit.Case, async: true

  alias Alto.BoundedFile

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-bounded-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "streams a multi-chunk digest and keeps bounded reads capped", %{dir: dir} do
    path = Path.join(dir, "large.bin")
    content = :binary.copy(<<"0123456789abcdef">>, 10_000)
    File.write!(path, content)

    assert {:ok, %{bytes: bytes, fingerprint: fingerprint}} = BoundedFile.digest(path)
    assert bytes == byte_size(content)
    assert fingerprint == :crypto.hash(:sha256, content)
    assert {:error, {:too_large, 11, 10}} = BoundedFile.read(path, 10)
  end
end
