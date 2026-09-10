defmodule Alto.Harness.ProviderProfileTest do
  use ExUnit.Case, async: true

  alias Alto.Harness.ProviderProfile

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_opts), do: %{}
    def list_models(_opts), do: {:ok, [%{id: "large", name: "Large"}]}
    def stream(_request, _sink, _opts), do: {:ok, %{message: "ok", tool_calls: []}}
  end

  test "normalizes selectable profiles and patches only the selected model" do
    opts = [
      provider_profiles: [
        [
          id: "local",
          label: "Local",
          provider: {Provider, base_url: "http://local"},
          models: :discover
        ]
      ]
    ]

    assert {:ok, [profile]} = ProviderProfile.from_run_options(opts)
    assert profile.id == "local"
    assert {:ok, [%{id: "large"}]} = ProviderProfile.models(profile)
    assert {Provider, provider_opts} = ProviderProfile.provider(profile, "large")
    assert provider_opts[:base_url] == "http://local"
    assert provider_opts[:model] == "large"
  end

  test "rejects duplicate ids" do
    profile = [id: "same", provider: Provider, models: ["one"]]

    assert {:error, :duplicate_profile_id} =
             ProviderProfile.from_run_options(provider_profiles: [profile, profile])
  end
end
