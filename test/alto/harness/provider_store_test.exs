defmodule Alto.Harness.ProviderStoreTest do
  use ExUnit.Case, async: true

  alias Alto.Harness.{ProviderProfile, ProviderStore}

  setup do
    root =
      Path.join(System.tmp_dir!(), "alto-provider-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: Path.join(root, "credentials.json")}
  end

  test "saved profiles expose metadata but resolve the API key only at runtime", %{path: path} do
    assert {:ok, saved} =
             ProviderStore.save(
               %{
                 id: "acme",
                 label: "Acme",
                 base_url: "https://api.acme.test/v1/",
                 api_key: "secret",
                 model: "acme/coder"
               },
               credentials_path: path
             )

    refute Keyword.has_key?(saved.options, :api_key)
    assert saved.options[:base_url] == "https://api.acme.test/v1"
    assert ProviderStore.api_key_saved?(saved, credentials_path: path)

    assert [profile] = elem(ProviderStore.profiles([], credentials_path: path), 1)
    refute inspect(profile) =~ "secret"
    assert ProviderStore.runtime_options(profile, credentials_path: path)[:api_key] == "secret"
  end

  test "decorates configured profiles without putting credentials in them", %{path: path} do
    assert {:ok, _saved} =
             ProviderStore.save(
               %{
                 id: "openrouter",
                 label: "My OpenRouter",
                 base_url: "https://openrouter.ai/api/v1",
                 api_key: "secret",
                 model: "vendor/model"
               },
               credentials_path: path
             )

    configured = %ProviderProfile{
      id: "openrouter",
      label: "OpenRouter",
      module: Alto.Providers.OpenAICompatible,
      options: [timeout: 1_000],
      models: :discover,
      credential_id: "openrouter"
    }

    assert {:ok, [profile]} = ProviderStore.profiles([configured], credentials_path: path)
    assert profile.label == "My OpenRouter"
    assert profile.default_model == "vendor/model"
    refute Keyword.has_key?(profile.options, :api_key)
  end
end
