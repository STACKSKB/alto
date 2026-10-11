# The service owns profile, tools, prompts, limits, decisions and saved tasks.
[
  tui_backends: [
    resident:
      {Alto.TUI.Backends.Remote,
       label: "Alto resident",
       profile: System.get_env("ALTO_RESIDENT_PROFILE") || "local",
       socket:
         System.get_env("ALTO_RESIDENT_SOCKET") ||
           Path.join(Alto.Contrib.Resident.Config.default_state_dir(), "service.sock")}
  ]
]
