defmodule Alto.Harness.ProviderProfileTest do
  use ExUnit.Case, async: true

  alias Alto.Harness.ProviderProfile

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(opts) do
      report(:describe, opts)
      %{}
    end

    def list_models(opts) do
      report(:models, opts)
      {:ok, [%{id: "large", name: "Large"}]}
    end

    def stream(_request, _sink, opts) do
      report(:stream, opts)
      {:ok, %{message: "ok", tool_calls: []}}
    end

    defp report(kind, opts) do
      Keyword.validate!(opts, [:owner, :base_url, :model, :timeout, :input_modalities])
      if opts[:owner], do: send(opts[:owner], {kind, opts})
    end
  end

  test "discovery and runtime model selection preserve connection options" do
    owner = self()
    connection = [base_url: "http://local", owner: owner, timeout: 500]

    opts = [
      provider_profiles: [
        %ProviderProfile{
          id: "local",
          label: "Local",
          provider: Alto.Provider.observe({Provider, connection}, &send(owner, {:observed, &1}))
        }
      ]
    ]

    assert {:ok, [profile]} = ProviderProfile.from_run_options(opts)
    assert {:ok, [%{id: "large"}]} = ProviderProfile.models(profile)
    assert_received {:models, ^connection}
    provider = ProviderProfile.runtime_provider(profile, "large")

    assert %Alto.Runner.Result{status: :ok, output: "ok"} =
             Alto.run("hello",
               provider: provider,
               loop: Alto.default_loop(context: Alto.Context.Window.new()),
               tools: []
             )

    selected =
      connection |> Keyword.put(:model, "large") |> Keyword.put(:input_modalities, ["text"])

    assert_received {:describe, ^selected}
    assert_received {:stream, ^selected}
    assert_received {:observed, %{messages: [_ | _]}}
  end

  test "configured model catalogs are returned without discovery" do
    catalog = [%{id: "small", name: "Small", context_length: 123}]

    assert {:ok, [profile]} =
             ProviderProfile.from_run_options(
               provider_profiles: [
                 %ProviderProfile{
                   id: "plain",
                   provider: {Provider, owner: self()},
                   models: catalog
                 }
               ]
             )

    assert {:ok, ^catalog} = ProviderProfile.models(profile)
    refute_received {:models, _}
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
