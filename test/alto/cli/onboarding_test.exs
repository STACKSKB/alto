defmodule Alto.CLI.OnboardingTest do
  use ExUnit.Case, async: true

  alias Alto.CLI.Onboarding
  alias Alto.Credentials

  defmodule CatalogProvider do
    def list_models(opts), do: {:ok, Keyword.fetch!(opts, :models)}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-onboarding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{credentials_path: Path.join(root, "credentials.json")}
  end

  test "prompts for a key, discovers models, and persists the selection", context do
    {:ok, input} = StringIO.open("new-secret\n2\n")
    {:ok, output} = StringIO.open("")

    assert {:ok, %{api_key: "new-secret", model: "openai/gpt"}} =
             Onboarding.resolve(
               credentials_path: context.credentials_path,
               interactive: true,
               input: input,
               output: output,
               provider: CatalogProvider,
               provider_options: [
                 models: [
                   %{id: "anthropic/claude", name: "Claude", context_length: 200_000},
                   %{id: "openai/gpt", name: "GPT", context_length: 128_000}
                 ]
               ]
             )

    {_input, body} = StringIO.contents(output)
    assert body =~ "OpenRouter API key"
    assert body =~ "anthropic/claude"
    assert body =~ "Selected openai/gpt"
    refute body =~ "new-secret"

    assert {:ok, credentials} = Credentials.load(context.credentials_path)
    assert Credentials.get(credentials, "openrouter", "api_key") == "new-secret"
    assert Credentials.get(credentials, "openrouter", "model") == "openai/gpt"
  end

  test "reuses saved credentials without prompting or fetching models", context do
    assert {:ok, credentials} = Credentials.load(context.credentials_path)

    assert {:ok, _credentials} =
             Credentials.put(credentials, "openrouter", %{
               "api_key" => "saved-key",
               "model" => "saved/model"
             })

    assert {:ok, %{api_key: "saved-key", model: "saved/model"}} =
             Onboarding.resolve(
               credentials_path: context.credentials_path,
               interactive: false,
               provider: CatalogProvider,
               provider_options: []
             )
  end

  test "environment values take precedence without being persisted", context do
    assert {:ok, %{api_key: "environment-key", model: "environment/model"}} =
             Onboarding.resolve(
               credentials_path: context.credentials_path,
               interactive: false,
               api_key: "environment-key",
               model: "environment/model",
               provider: CatalogProvider,
               provider_options: []
             )

    assert {:ok, credentials} = Credentials.load(context.credentials_path)
    assert credentials.providers == %{}
  end

  test "fails clearly when onboarding is required without a terminal", context do
    assert {:error, message} =
             Onboarding.resolve(
               credentials_path: context.credentials_path,
               interactive: false,
               provider: CatalogProvider,
               provider_options: []
             )

    assert message =~ "OPENROUTER_API_KEY"
    assert message =~ "alto --setup"
  end

  test "filters a long catalog before selection", context do
    {:ok, input} = StringIO.open("secret\nclaude\n1\n")
    {:ok, output} = StringIO.open("")

    models = [
      %{id: "openai/gpt", name: "GPT", context_length: 128_000},
      %{id: "anthropic/claude-sonnet", name: "Claude Sonnet", context_length: 200_000},
      %{id: "anthropic/claude-opus", name: "Claude Opus", context_length: 200_000}
    ]

    assert {:ok, %{model: "anthropic/claude-sonnet"}} =
             Onboarding.resolve(
               credentials_path: context.credentials_path,
               interactive: true,
               input: input,
               output: output,
               provider: CatalogProvider,
               provider_options: [models: models]
             )
  end
end
