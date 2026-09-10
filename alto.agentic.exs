# Full local coding-harness profile. Alto never auto-executes a repository
# configuration; select it explicitly:
#
#   mix alto --config alto.agentic.exs --allow-write --sandbox-command "task"
#
# FFF and Ripwire stay independent installations. Their absolute paths may be
# provided when the desktop process does not inherit the interactive PATH:
# FFF_MCP=/path/to/fff-mcp and RIPWIRE_BIN=/path/to/ripwire.

mix_home = System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")

command_executor =
  {Alto.Command.Executors.Bubblewrap,
   network: :disabled,
   read_only_paths: [mix_home],
   env: %{"MIX_HOME" => mix_home, "HEX_HOME" => mix_home}}

openrouter_model = System.get_env("ALTO_MODEL")

openrouter_options =
  [
    base_url: "https://openrouter.ai/api/v1",
    model: openrouter_model,
    timeout: 120_000,
    model_query: [supported_parameters: "tools", sort: "most-popular"]
  ]
  |> Keyword.reject(fn {_key, value} -> is_nil(value) end)

external = fn env_name, executable ->
  case System.get_env(env_name) do
    path when is_binary(path) and path != "" -> path
    _other -> System.find_executable(executable)
  end
end

fff_tools =
  case external.("FFF_MCP", "fff-mcp") do
    nil ->
      # Existing Alto search remains a bounded degraded mode, not an FFF clone.
      [Alto.Tools.SearchFiles]

    executable ->
      Alto.Tools.FFF.tools(executable: executable)
  end

ripwire_tools =
  case external.("RIPWIRE_BIN", "ripwire") do
    nil -> []
    executable -> [{Alto.Tools.Ripwire, executable: executable}]
  end

Alto.Config.new(
  codex_backend: [
    command: System.get_env("CODEX_BIN") || "codex",
    model: System.get_env("ALTO_CODEX_MODEL")
  ],
  provider_profiles: [
    [
      id: "openrouter",
      label: "OpenRouter",
      provider: {Alto.Providers.OpenAICompatible, openrouter_options},
      models: :discover,
      default_model: openrouter_model,
      credential_id: "openrouter"
    ]
  ],
  loop: Alto.default_loop(),
  tools:
    [
      Alto.Tools.ListFiles,
      Alto.Tools.ReadFile,
      Alto.Tools.EditFile,
      Alto.Tools.WriteFile,
      {Alto.Tools.GitInspect, executor: command_executor},
      {Alto.Tools.GitMutate, executor: command_executor},
      {Alto.Tools.RunCommand, executor: command_executor}
    ] ++ fff_tools ++ ripwire_tools,
  approval: Alto.Approvals.Interactive,
  prompt: Alto.Prompts.Coding,
  tui: [
    type_to_compose: true,
    narrow_context: :adaptive,
    narrow_context_width: 75,
    narrow_context_fullscreen_below: 72,
    approval_auto_open: true
  ],
  project_instructions: :auto,
  sessions: true,
  max_steps: 96,
  compaction: [
    strategy: :handoff,
    keep_recent_messages: 12,
    max_handoff_bytes: 24_000
  ],
  provider_retries: 3
)
