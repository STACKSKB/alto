# Full local coding-harness profile. Alto never auto-executes a repository
# configuration; select it explicitly:
#
#   mix alto --config alto.agentic.exs --allow-write --sandbox-command "task"
#
# FFF and Ripwire stay independent installations. Their absolute paths may be
# provided when the desktop process does not inherit the interactive PATH:
# FFF_MCP=/path/to/fff-mcp and RIPWIRE_BIN=/path/to/ripwire.

require Logger

mix_home = System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")

command_executor =
  {Alto.Command.Executors.Bubblewrap,
   network: :disabled,
   protected_paths: [".git"],
   read_only_paths: [mix_home],
   env: %{"MIX_HOME" => mix_home, "HEX_HOME" => mix_home}}

openrouter_model = System.get_env("ALTO_MODEL")
vision_enabled = System.get_env("ALTO_VISION") == "1"

openrouter_options =
  [
    base_url: "https://openrouter.ai/api/v1",
    model: openrouter_model,
    timeout: 120_000,
    supports_images: vision_enabled,
    model_query: [supported_parameters: "tools", sort: "most-popular"]
  ]
  |> Keyword.reject(fn {_key, value} -> is_nil(value) end)

openrouter_provider = {Alto.Providers.OpenAICompatible, openrouter_options}

openrouter_provider =
  if System.get_env("ALTO_REQUEST_DIAGNOSTICS") == "1" do
    Alto.Providers.Observe.wrap(openrouter_provider, fn request ->
      Logger.debug(fn ->
        report = Alto.Providers.PrefixContinuity.report(request)
        "Alto prefix continuity: #{inspect(report)}"
      end)
    end)
  else
    openrouter_provider
  end

external = fn env_name, executable ->
  case System.get_env(env_name) do
    path when is_binary(path) and path != "" -> path
    _other -> System.find_executable(executable)
  end
end

# Expose only the selected executable; extra runtimes remain host configuration.
external_executor = fn executable ->
  {module, options} = command_executor
  {module, Keyword.update!(options, :read_only_paths, &[executable | &1])}
end

fff_tools =
  case external.("FFF_MCP", "fff-mcp") do
    nil ->
      # Existing Alto search remains a bounded degraded mode, not an FFF clone.
      [Alto.Tools.SearchFiles]

    executable ->
      Alto.Tools.FFF.tools(executable: executable, executor: external_executor.(executable))
  end

ripwire_tools =
  case external.("RIPWIRE_BIN", "ripwire") do
    nil ->
      []

    executable ->
      [{Alto.Tools.Ripwire, executable: executable, executor: external_executor.(executable)}]
  end

Alto.Config.new(
  provider_profiles: [
    [
      id: "openrouter",
      label: "OpenRouter",
      provider: openrouter_provider,
      models: :discover,
      default_model: openrouter_model,
      credential_id: "openrouter"
    ]
  ],
  loop:
    Alto.default_loop(
      tool_execution: {:parallel, 4},
      context:
        Alto.Context.window(compact_at: 0.85, reserve_output: 4_096, usage_estimation: true)
    ),
  tools:
    [
      Alto.Tools.ListFiles,
      Alto.Tools.ReadFile,
      Alto.Tools.ProtectPaths.wrap(Alto.Tools.EditFile, [".git"]),
      Alto.Tools.ProtectPaths.wrap(Alto.Tools.WriteFile, [".git"]),
      {Alto.Tools.GitInspect, executor: command_executor},
      # Git mutation is a distinct, explicitly approved capability.
      {Alto.Tools.GitMutate,
       executor:
         {Alto.Command.Executors.Bubblewrap,
          Keyword.put(elem(command_executor, 1), :protected_paths, [])}},
      {Alto.Tools.RunCommand, executor: command_executor}
    ] ++ if(vision_enabled, do: [Alto.Tools.ReadImage], else: []) ++ fff_tools ++ ripwire_tools,
  tui_backends: [
    alto: {Alto.TUI.Backends.Native, label: "Alto native"},
    codex:
      {Alto.TUI.Backends.Codex,
       label: "Codex · ChatGPT",
       command: System.get_env("CODEX_BIN") || "codex",
       model: System.get_env("ALTO_CODEX_MODEL")}
  ],
  tool_presenter: {Alto.ToolDisplay, []},
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
  session_history: :settled,
  max_steps: 96,
  max_tool_result_bytes: if(vision_enabled, do: 1_500_000, else: 64_000),
  compaction: [
    strategy: {Alto.Context.Reducers.Handoff, []},
    max_compactions: 8,
    keep_recent_messages: 12,
    keep_initial_messages: 1,
    max_input_bytes: 1_000_000,
    max_handoff_bytes: 24_000
  ],
  retry_policy: {Alto.Retry.Transient, base_delay: 500, max_delay: 5_000},
  provider_retries: 3
)
