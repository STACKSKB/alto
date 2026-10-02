# Bounded parallel investigation: one parent, at most three read-only children,
# two at a time, with separate saved sessions. Shared workspace; no write tools.
# Delegation needs approval. Choose a model with at least 32k context or adjust
# the cap below. See examples/README.md for setup and per-run budget semantics.

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
  loop:
    Alto.default_loop(
      tool_execution: {:parallel, 4},
      subagents:
        Alto.Subagents.bounded(
          max_depth: 1,
          max_children: 3,
          max_concurrency: 2,
          sessions: :separate
        ),
      # Adjust this conservative cap for your model; no catalog lookup is needed.
      context:
        Alto.Context.Window.new(
          max_tokens: 32_768,
          compact_at: 0.8,
          reserve_output: 4_096,
          usage_estimation: true
        )
    ),
  tools:
    [
      Alto.Contrib.Tools.ListFiles,
      Alto.Contrib.Tools.ReadFile,
      Alto.Contrib.Tools.SearchFiles,
      Alto.Contrib.Tools.GitInspect
    ] ++
      Alto.Contrib.Tools.agents(
        only: [:list_agent_models, :spawn_agents],
        models: %{"configured" => [model]}
      ),
  approval: &Alto.Contrib.Approval.interactive/2,
  prompt: fn context ->
    Alto.Prompt.render([
      Alto.Contrib.Prompts.Coding.build(context),
      "Investigate the workspace without modifying it. For independent questions, use list_agent_models and spawn_agents with backend configured. Delegate at most three focused assignments, then reconcile their evidence and report concrete file references. Children may inspect the same workspace but cannot delegate further."
    ])
  end,
  max_steps: 48,
  max_model_requests: 48,
  run_timeout: 1_800_000,
  compaction: [
    strategy: Alto.Contrib.Context.Reducers.Summary,
    max_compactions: 3,
    keep_recent_messages: 6,
    keep_initial_messages: 1,
    max_input_bytes: 1_000_000,
    max_summary_bytes: 8_000
  ]
)
