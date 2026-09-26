defmodule Alto.Harness.ProviderProfileTest do
  use ExUnit.Case, async: true

  alias Alto.Harness.ProviderProfile

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_opts), do: %{}
    def list_models(_opts), do: {:ok, [%{id: "large", name: "Large"}]}
    def stream(_request, _sink, _opts), do: {:ok, %{message: "ok", tool_calls: []}}
  end

  test "discovery and runtime model selection preserve connection options" do
    opts = [
      provider_profiles: [
        %ProviderProfile{
          id: "local",
          label: "Local",
          provider: {Provider, base_url: "http://local"}
        }
      ]
    ]

    assert {:ok, [profile]} = ProviderProfile.from_run_options(opts)
    assert {:ok, [%{id: "large"}]} = ProviderProfile.models(profile)
    assert {Provider, provider_opts} = ProviderProfile.runtime_provider(profile, "large")
    assert provider_opts[:base_url] == "http://local"
    assert provider_opts[:model] == "large"
  end

  test "profile structs share defaults without losing options or catalog metadata" do
    catalog = [%{id: "small", name: "Small", context_length: 123}]

    assert {:ok, [plain, configured]} =
             ProviderProfile.from_run_options(
               provider_profiles: [
                 %ProviderProfile{id: "plain", provider: {Provider, []}, models: catalog},
                 %ProviderProfile{
                   id: "configured",
                   provider: {Provider, model: "large", timeout: 500}
                 }
               ]
             )

    assert plain.label == "plain"
    assert plain.credential_id == "plain"
    assert {:ok, ^catalog} = ProviderProfile.models(plain)
    assert configured.default_model == "large"
    assert {Provider, options} = ProviderProfile.runtime_provider(configured, "selected")
    assert options[:timeout] == 500
    assert options[:model] == "selected"
  end

  test "rejects duplicate ids" do
    profile = %ProviderProfile{id: "same", provider: {Provider, []}, models: [%{id: "one"}]}

    assert {:error, :duplicate_profile_id} =
             ProviderProfile.from_run_options(provider_profiles: [profile, profile])
  end

  test "discovers models from a provider that has not been loaded yet" do
    directory =
      Path.join(System.tmp_dir!(), "alto-cold-provider-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    module = Alto.Test.ColdCatalogProvider

    [{^module, beam}] =
      Code.compile_string("""
      defmodule Alto.Test.ColdCatalogProvider do
        def list_models(_), do: {:ok, [%{id: "first-run"}]}
      end
      """)

    File.write!(Path.join(directory, "#{module}.beam"), beam)
    :code.purge(module)
    :code.delete(module)
    Code.prepend_path(directory)

    on_exit(fn ->
      Code.delete_path(directory)
      :code.purge(module)
      :code.delete(module)
      File.rm_rf!(directory)
    end)

    refute function_exported?(module, :list_models, 1)

    profile = %ProviderProfile{
      id: "cold",
      label: "Cold",
      provider: {module, []},
      models: :discover
    }

    assert {:ok, [%{id: "first-run"}]} = ProviderProfile.models(profile)
  end
end
