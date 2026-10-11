config =
  Alto.Contrib.Resident.Config.new(
    workspace: System.fetch_env!("ALTO_RESIDENT_WORKSPACE"),
    state_dir:
      System.get_env("ALTO_RESIDENT_STATE_DIR") ||
        Alto.Contrib.Resident.Config.default_state_dir(),
    profiles: %{
      "inspect" =>
        Alto.Config.default(
          provider: nil,
          loop: Alto.rule_loop(steps: ["list_files"]),
          tools: [Alto.Contrib.Tools.ListFiles],
          approval: {:deny, :policy_denied},
          max_effects: 10,
          run_timeout: 10_000
        )
    }
  )

[resident: Map.to_list(Map.from_struct(config))]
