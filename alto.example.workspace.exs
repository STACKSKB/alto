# A Linux coding workspace with Bubblewrap, approvals, retained command output,
# and handoff compaction. Requires bwrap and a model with at least 32k context
# (or a smaller context cap below). Commands cannot use the network or write .git.
# See examples/README.md for prerequisites, compaction and retention cleanup.

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

executor =
  {Alto.Contrib.Command.Executors.Bubblewrap,
   network: :disabled,
   protected_paths: [".git"],
   output_retention: [directory: ".alto/command-output", max_bytes: 2_000_000, max_files: 8]}

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
  loop:
    Alto.default_loop(
      tool_execution: {:parallel, 4},
      # Adjust this conservative cap for your model; no catalog lookup is needed.
      context:
        Alto.Context.Window.new(
          max_tokens: 32_768,
          compact_at: 0.8,
          reserve_output: 4_096,
          usage_estimation: true
        )
    ),
  tools: [
    Alto.Contrib.Tools.ListFiles,
    Alto.Contrib.Tools.ReadFile,
    Alto.Contrib.Tools.SearchFiles,
    Alto.Contrib.Tools.ProtectPaths.wrap(Alto.Contrib.Tools.EditFile, [".git"]),
    Alto.Contrib.Tools.ProtectPaths.wrap(Alto.Contrib.Tools.WriteFile, [".git"]),
    {Alto.Contrib.Tools.GitInspect, executor: executor},
    {Alto.Contrib.Tools.RunCommand, executor: executor},
    {Alto.Contrib.Tools.RunShell, executor: executor}
  ],
  approval: &Alto.Contrib.Approval.interactive/2,
  prompt: fn context ->
    Alto.Prompt.render([
      Alto.Contrib.Prompts.Coding.build(context),
      "Commands run in a workspace sandbox with networking disabled and .git protected. Run the relevant tests before reporting completion. When command output is truncated, read the returned output_retention.path in bounded chunks."
    ])
  end,
  max_steps: 96,
  max_model_requests: 96,
  run_timeout: 3_600_000,
  compaction: [
    strategy: Alto.Contrib.Context.Reducers.Handoff,
    max_compactions: 4,
    keep_recent_messages: 6,
    keep_initial_messages: 1,
    max_input_bytes: 1_000_000,
    max_handoff_bytes: 24_000
  ]
)
