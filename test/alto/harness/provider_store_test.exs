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
    assert {:ok, [saved]} =
             ProviderStore.save(
               %{
                 id: "acme",
                 label: "Acme",
                 base_url: "https://api.acme.test/v1/",
                 api_key: "secret",
                 model: "acme/coder"
               },
               [],
               credentials_path: path
             )

    refute Keyword.has_key?(elem(saved.provider, 1), :api_key)
    assert elem(saved.provider, 1)[:base_url] == "https://api.acme.test/v1"
    assert ProviderStore.api_key_saved?(saved, credentials_path: path)

    assert [profile] = elem(ProviderStore.profiles([], credentials_path: path), 1)
    refute inspect(profile) =~ "secret"

    assert elem(ProviderStore.resolve(profile, credentials_path: path), 1)[:api_key] ==
             "secret"
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
               [],
               credentials_path: path
             )

    configured = %ProviderProfile{
      id: "configured",
      label: "OpenRouter",
      provider: {__MODULE__, [timeout: 1_000, custom: :preserved]},
      models: [%{id: "original", name: "Original", context_length: 123}],
      credential_id: "openrouter"
    }

    assert {:ok, [profile]} = ProviderStore.profiles([configured], credentials_path: path)
    assert profile.label == "My OpenRouter"
    assert profile.default_model == "vendor/model"
    refute Keyword.has_key?(elem(profile.provider, 1), :api_key)

    assert {:ok, [updated]} =
             ProviderStore.save(
               %{
                 id: "configured",
                 label: "Updated",
                 base_url: "https://new.test/v1",
                 model: "new/model",
                 api_key: "replacement-secret"
               },
               [configured],
               credentials_path: path
             )

    assert updated.models == configured.models
    assert updated.credential_id == "openrouter"
    assert {__MODULE__, options} = updated.provider
    assert options[:timeout] == 1_000
    assert options[:custom] == :preserved
    assert options[:base_url] == "https://new.test/v1"
    refute inspect(updated) =~ "replacement-secret"

    assert elem(ProviderStore.resolve(updated, credentials_path: path), 1)[:api_key] ==
             "replacement-secret"

    assert {:ok, [^updated]} = ProviderStore.profiles([configured], credentials_path: path)
    assert {:ok, credentials} = Alto.Credentials.load(path)
    refute Map.has_key?(credentials.providers, "configured")
  end
end
