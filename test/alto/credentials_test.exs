defmodule Alto.CredentialsTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Alto.Credentials

  setup do
    root = Path.join(System.tmp_dir!(), "alto-credentials-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: Path.join(root, "credentials.json")}
  end

  test "persists provider credentials with private permissions", %{path: path} do
    assert {:ok, credentials} = Credentials.load(path)
    assert Credentials.get(credentials, "openrouter", "api_key") == nil

    assert {:ok, credentials} =
             Credentials.put(credentials, "openrouter", %{
               "api_key" => "secret",
               "model" => "anthropic/claude-sonnet"
             })

    assert {:ok, stat} = File.stat(path)
    assert (stat.mode &&& 0o777) == 0o600
    refute inspect(credentials) =~ "secret"

    assert {:ok, loaded} = Credentials.load(path)
    assert Credentials.get(loaded, "openrouter", "api_key") == "secret"
    assert Credentials.get(loaded, "openrouter", "model") == "anthropic/claude-sonnet"
  end

  test "merges provider preferences without dropping an existing key", %{path: path} do
    assert {:ok, credentials} = Credentials.load(path)
    assert {:ok, credentials} = Credentials.put(credentials, "openrouter", %{"api_key" => "key"})
    assert {:ok, credentials} = Credentials.put(credentials, "openrouter", %{"model" => "model"})

    assert Credentials.get(credentials, "openrouter", "api_key") == "key"
    assert Credentials.get(credentials, "openrouter", "model") == "model"
  end

  test "rejects malformed and oversized files", %{path: path} do
    File.write!(path, "not json")
    assert {:error, {:invalid_credentials_json, _error}} = Credentials.load(path)

    File.write!(path, String.duplicate("x", 64_001))
    assert {:error, {:credentials_too_large, 64_000}} = Credentials.load(path)
  end

  test "refuses a well-formed store that group or other can read", %{path: path} do
    File.write!(
      path,
      JSON.encode!(%{"version" => 1, "providers" => %{"openrouter" => %{"api_key" => "secret"}}})
    )

    File.chmod!(path, 0o644)

    assert {:error, {:credentials_mode, ^path}} = Credentials.load(path)
  end
end
