# Offline, providerless service. Supply a different trusted profile for model work.
workspace = System.get_env("ALTO_RESIDENT_WORKSPACE") || File.cwd!()
state = System.get_env("ALTO_RESIDENT_STATE_DIR") || Alto.Contrib.Resident.Config.default_state_dir()
[
  resident: [workspace: workspace, state_dir: state,
    profiles: %{"local" => Alto.Config.default(provider: nil,
      loop: Alto.rule_loop(steps: ["list_files"]), tools: [Alto.Contrib.Tools.ListFiles])}]
]
