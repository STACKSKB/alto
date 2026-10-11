provider = fn model ->
  {Alto.Contrib.Providers.OpenAICompatible,
   base_url: System.fetch_env!("ALTO_RESIDENT_PROVIDER_URL"),
   model: model,
   api_key: System.get_env("ALTO_RESIDENT_API_KEY")}
end

state =
  System.get_env("ALTO_RESIDENT_STATE_DIR") || Alto.Contrib.Resident.Config.default_state_dir()

manager = Alto.Contrib.Resident.Workspaces.manager(state)

inspection = [
  Alto.Contrib.Tools.ListFiles,
  Alto.Contrib.Tools.ReadFile,
  Alto.Contrib.Tools.SearchFiles
]

writes = [Alto.Contrib.Tools.WriteFile, Alto.Contrib.Tools.EditFile]

workers = %{
  "code" => [
    provider: provider.(System.fetch_env!("ALTO_RESIDENT_WORKER_MODEL")),
    tools: inspection ++ writes,
    model_tools: [:list_files, :read_file, :search_files, :write_file, :edit_file],
    max_steps: 12,
    system_prompt:
      "Implement the assigned change in your isolated checkout using the file tools. " <>
        "Report what changed and any checks or limitations. Do not delegate."
  ]
}

config =
  Alto.Contrib.Resident.Config.new(
    workspace: System.fetch_env!("ALTO_RESIDENT_WORKSPACE"),
    state_dir: state,
    profiles: %{
      "coding" =>
        Alto.Config.default(
          provider: provider.(System.fetch_env!("ALTO_RESIDENT_MODEL")),
          prompt:
            Alto.Contrib.Resident.Team.instructions(workers, 4) <>
              " Workers edit independent checkouts. Review every patch with review_worker_patch, " <>
              "then request apply_worker_patch with the exact workspace ID and revision. " <>
              "Check each tool result; report conflicts and uncertainty without retrying them.",
          loop:
            Alto.Contrib.Resident.Team.loop(
              workers: workers,
              max_children: 4,
              max_concurrency: 2,
              workspaces: manager
            ),
          tools:
            inspection ++
              writes ++
              [
                {Alto.Contrib.Resident.Tools.ReviewWorkerPatch, manager: manager},
                {Alto.Contrib.Resident.Tools.ApplyWorkerPatch, manager: manager}
              ],
          model_tools: [
            :list_files,
            :read_file,
            :search_files,
            :write_file,
            :edit_file,
            :review_worker_patch,
            :apply_worker_patch
          ],
          approval: Alto.Contrib.Resident.Approvals.CodingTeam.policy(manager: manager),
          continuation_store: Alto.Contrib.Resident.ParentRuns.ledger(),
          checkpoint_version: "coding-team-v1",
          max_steps: 24,
          max_model_requests: 72,
          max_effects: 240,
          run_timeout: 600_000
        )
    }
  )

[resident: Map.to_list(Map.from_struct(config))]
