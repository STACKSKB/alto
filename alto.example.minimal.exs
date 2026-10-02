# A small interactive coding agent: read, exact edits, write, and direct commands.
# Commands run on the HOST with its permissions and network; approval is required.
# See examples/README.md for setup, workspace selection and saved sessions.

# Select a tool-capable Chat Completions model explicitly. No model discovery or
# network access occurs while loading this file. Local endpoints may omit a key.
model = String.trim(System.get_env("ALTO_MODEL") || "")
if model == "", do: raise("Set ALTO_MODEL to a tool-capable model ID before loading this example")

provider =
  {Alto.Contrib.Providers.OpenAICompatible,
   base_url: System.get_env("ALTO_BASE_URL") || "https://openrouter.ai/api/v1",
   api_key: System.get_env("ALTO_API_KEY") || System.get_env("OPENROUTER_API_KEY"),
   model: model,
   timeout: 120_000,
   idle_timeout: 60_000,
   input_modalities: ["text"]}

# The same explicit catalog serves the CLI, TUI and (where enabled) child agents.
profiles = [
  %Alto.Contrib.ProviderProfile{
    id: "configured",
    label: "Configured provider",
    provider: provider,
    models: [%{id: model, input_modalities: ["text"]}],
    default_model: model
  }
]

Alto.default_config()
|> Keyword.merge(
  provider: provider,
  provider_profiles: profiles,
  project_instructions: :auto,
  session: :new,
  sessions: true,
  session_history: :settled,
  provider_timeout: 125_000,
  tool_timeout: 125_000,
  max_tool_result_bytes: 256_000,
  max_transcript_bytes: 4_000_000,
  max_conversation_bytes: 16_000_000,
  max_event_bytes: 8_000_000,
  provider_retries: 2,
  loop: Alto.default_loop(),
  tools: [
    Alto.Contrib.Tools.ReadFile,
    Alto.Contrib.Tools.EditFile,
    Alto.Contrib.Tools.WriteFile,
    {Alto.Contrib.Tools.RunCommand, executor: Alto.Contrib.Command.Executors.Unsandboxed}
  ],
  approval: &Alto.Contrib.Approval.interactive/2,
  prompt: &Alto.Contrib.Prompts.Coding.build/1,
  max_steps: 32,
  max_model_requests: 32,
  run_timeout: 900_000
)
