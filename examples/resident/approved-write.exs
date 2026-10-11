# Write a real workspace file after a durable, revision-fenced decision.
# ./zekkyou serve examples/approved-write.exs
# ./zekkyou schedule write '{"path":"notes.txt","content":"Reviewed content"}'
# Inspect with `task ID`, then `task-decide ID approve --revision N`.
config = Alto.Contrib.Resident.Config.new(
  workspace: System.fetch_env!("ALTO_RESIDENT_WORKSPACE"),
  state_dir: System.get_env("ALTO_RESIDENT_STATE_DIR") || Alto.Contrib.Resident.Config.default_state_dir(),
  profiles: %{
    "write" =>
      Alto.Config.default(
        provider: nil,
        loop: Alto.rule_loop(steps: ["write_file"]),
        tools: [Alto.Contrib.Tools.WriteFile],
        approval: :suspend,
        checkpoint_version: "approved-write-v1"
      )
  }
)

[resident: Map.to_list(Map.from_struct(config))]
