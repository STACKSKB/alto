provider = fn model ->
  {Alto.Contrib.Providers.OpenAICompatible,
   base_url: System.fetch_env!("ALTO_RESIDENT_PROVIDER_URL"),
   model: model,
   api_key: System.get_env("ALTO_RESIDENT_API_KEY")}
end

inspection = [
  Alto.Contrib.Tools.ListFiles,
  Alto.Contrib.Tools.ReadFile,
  Alto.Contrib.Tools.SearchFiles,
  Alto.Contrib.Resident.Tools.Mailbox
]

workers = %{
  "inspect" => [
    provider: provider.(System.fetch_env!("ALTO_RESIDENT_WORKER_MODEL")),
    tools: inspection,
    max_steps: 8,
    system_prompt:
      "Inspect the assigned part of the workspace. Report evidence with file paths. " <>
        "Do not delegate or edit files. Clearly distinguish findings from guesses. " <>
        "You may send useful findings to the lead at mailbox address []."
  ]
}

config =
  Alto.Contrib.Resident.Config.new(
    workspace: System.fetch_env!("ALTO_RESIDENT_WORKSPACE"),
    state_dir:
      System.get_env("ALTO_RESIDENT_STATE_DIR") ||
        Alto.Contrib.Resident.Config.default_state_dir(),
    child_runs: [max_retained: 128, max_log_bytes: 64_000_000, max_batch_bytes: 1_000_000],
    profiles: %{
      "team" =>
        Alto.Config.default(
          provider: provider.(System.fetch_env!("ALTO_RESIDENT_MODEL")),
          continuation_store: Alto.Contrib.Resident.ParentRuns.ledger(),
          prompt: Alto.Contrib.Resident.Team.instructions(workers, 4),
          loop:
            Alto.Contrib.Resident.Team.loop(
              workers: workers,
              max_children: 4,
              max_concurrency: 2,
              sessions: :separate
            ),
          tools: inspection ++ [Alto.Contrib.Tools.WriteFile],
          approval: :suspend,
          checkpoint_version: "team-v2-parent-recovery",
          max_steps: 16,
          max_model_requests: 48,
          max_effects: 200,
          run_timeout: 600_000
        )
    }
  )

[resident: Map.to_list(Map.from_struct(config))]
