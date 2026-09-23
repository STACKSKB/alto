require Logger
alias ExRatatui.Event.Key
alias ExRatatui.Runtime

[root, scenario] = System.argv()
Logger.configure(level: :debug)
{:ok, _} = Application.ensure_all_started(:alto)
original = :logger.get_handler_config()
fixture = self()

config =
  Alto.Config.new(
    tui_backends: [alto: {Alto.TUI.Backends.Native, []}],
    provider_profiles: [],
    tools: [],
    loop: Alto.chat_loop()
  )

if scenario != "startup_failure" do
  spawn(fn ->
    app =
      Enum.reduce_while(1..500, nil, fn _, _ ->
        case Process.whereis(:tui_logging_fixture) do
          nil ->
            Process.sleep(10)
            {:cont, nil}

          pid ->
            {:halt, pid}
        end
      end)

    # Synchronize with initialization and the first real terminal draw.
    Runtime.snapshot(app)
    Logger.debug("TUI_DEBUG_MUST_STAY_IN_FILE")
    Logger.warning("TUI_WARNING_MUST_STAY_IN_FILE")
    Logger.error("TUI_ERROR_MUST_STAY_IN_FILE")
    Logger.flush()
    Runtime.inject_event(app, %Key{code: "x", kind: "press", modifiers: []})

    case scenario do
      "crash" ->
        GenServer.stop(app, :fixture_failure)

      "owner_exit" ->
        send(fixture, :terminate_owner)

      "normal" ->
        Runtime.inject_event(app, %Key{code: "g", kind: "press", modifiers: ["ctrl"]})
        Runtime.inject_event(app, %Key{code: "q", kind: "press", modifiers: []})
    end
  end)
end

catalog = Path.join(root, "catalog.json")
project = if scenario == "startup_failure", do: Path.join(root, "missing-project"), else: root

options =
  [
    name: :tui_logging_fixture,
    project: project,
    path: catalog,
    credentials_path: Path.join(root, "credentials.json"),
    log_path: Path.join(root, "tui.log")
  ]

result =
  if scenario == "owner_exit" do
    {caller, monitor} = spawn_monitor(fn -> Alto.TUI.run(config, options) end)

    # The controller logs and renders before signalling that the caller can exit.
    receive do
      :terminate_owner -> Process.exit(caller, :kill)
    after
      10_000 -> raise "TUI never became ready"
    end

    receive do
      {:DOWN, ^monitor, :process, ^caller, :killed} -> :ok
    end

    Enum.reduce_while(1..500, nil, fn _, _ ->
      if :logger.get_handler_config() != original do
        Process.sleep(10)
        {:cont, nil}
      else
        {:halt, :ok}
      end
    end)
  else
    Alto.TUI.run(config, options)
  end

case {scenario, result} do
  {"normal", :ok} -> :ok
  {"owner_exit", :ok} -> :ok
  {"crash", {:error, {:tui_stopped, :fixture_failure}}} -> :ok
  {"startup_failure", {:error, _}} -> :ok
  other -> raise "unexpected result: #{inspect(other)}"
end

unless :logger.get_handler_config() == original,
  do:
    raise(
      "logger configuration not restored: #{inspect({original, :logger.get_handler_config()})}"
    )

Logger.warning("TUI_CONSOLE_RESTORED")
Logger.flush()
