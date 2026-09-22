defmodule Alto.CLI do
  @moduledoc "Plain-stdio command-line entry point for the execution host."

  alias Alto.Approvals.AllowAll
  alias Alto.Approvals.Interactive
  alias Alto.Approvals.Socket, as: SocketApproval
  alias Alto.CLI.Arguments
  alias Alto.CLI.Onboarding
  alias Alto.Config
  alias Alto.CLI.Renderer
  alias Alto.FrontEnd.Registry
  alias Alto.Listeners.UnixSocket
  alias Alto.Listeners.WebServer
  alias Alto.Listeners.Webhook
  alias Alto.Providers.OpenAICompatible
  alias Alto.Session
  alias Alto.Tools.EditFile
  alias Alto.Tools.ListFiles
  alias Alto.Tools.ReadFile
  alias Alto.Tools.RunCommand
  alias Alto.Tools.SearchFiles
  alias Alto.Tools.WriteFile

  @spec main([binary()]) :: no_return()
  def main(argv) do
    case run(argv) do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, "alto: " <> message)
        System.halt(1)
    end
  end

  @spec run([binary()]) :: :ok | {:error, binary()}
  def run(argv) do
    with {:ok, _applications} <- Application.ensure_all_started(:alto),
         {:ok, options, task} <- Arguments.parse(argv),
         :continue <- Arguments.maybe_help(options) do
      result =
        cond do
          Keyword.get(options, :sessions, false) -> sessions(options, task)
          Keyword.get(options, :serve, false) -> serve(options, task)
          Keyword.get(options, :setup, false) -> setup(options, task)
          true -> execute(options, task)
        end

      format_result(result)
    else
      :help -> :ok
      {:error, reason} -> format_result({:error, reason})
    end
  end

  defp format_result(:ok), do: :ok
  defp format_result({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp format_result({:error, reason}), do: {:error, format_reason(reason)}

  defp execute(options, task_words) do
    with {:ok, task} <- task_text(task_words),
         {:ok, config} <- load_config(options),
         {:ok, command_mode} <- command_mode(options),
         {:ok, run_options, renderer} <- run_options(options, config, command_mode) do
      try do
        case run_task(options, task, run_options) do
          {:ok, result} ->
            Renderer.finish(result.output, Renderer.stop(renderer))
            IO.write("\n")
            report_session(result.session_id)
            :ok

          {:error, reason, result} ->
            Renderer.stop(renderer)
            IO.write("\n")
            report_session(result.session_id)
            {:error, reason}

          {:error, reason} ->
            Renderer.stop(renderer)
            IO.write("\n")
            {:error, reason}
        end
      after
        # A run that crashes before reaching the case above would otherwise
        # leak the renderer process.
        Renderer.stop(renderer)
      end
    end
  end

  defp run_task(options, task, run_options) do
    case Keyword.get(options, :resume) do
      nil -> Alto.run(task, run_options)
      session_id -> Alto.resume(session_id, task, run_options)
    end
  end

  defp report_session(nil), do: :ok

  defp report_session(id),
    do: IO.puts(:stderr, "alto: session #{id} (resume with --resume #{id})")

  defp sessions(_options, task) when task != [], do: {:error, "--sessions does not accept a task"}

  defp sessions(_options, []) do
    case Session.list() do
      {:ok, []} ->
        IO.puts("no sessions yet")
        :ok

      {:ok, summaries} ->
        Enum.each(summaries, fn summary ->
          IO.puts(
            "#{summary.id}  #{format_session_time(summary.started_at_ms)}" <>
              "  runs:#{summary.runs} completed:#{summary.completed_runs}" <>
              "  last:#{summary.last_outcome || "-"}  #{summary.task || ""}"
          )
        end)

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_session_time(nil), do: "-"

  defp format_session_time(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, time} -> DateTime.to_iso8601(time)
      {:error, _reason} -> inspect(ms)
    end
  end

  ## Resident server (`--serve`)
  ##
  ## The server loads one trusted configuration (same discovery as one-shot
  ## runs) and serves it to front ends under the name `"default"`, plus one
  ## entry per key of the optional `runs:` map (named compiled run specs for
  ## webhook endpoints such as `"job"`). The WebSocket client's config field
  ## defaults to `"default"`, and `start_run` with any other name fails with
  ## `unknown_config`. Runs started this way have no terminal to prompt on,
  ## so approval is forced to `Alto.Approvals.Socket` unless the operator
  ## explicitly passes `--approve-all`.

  @default_serve_port 4_747
  @default_webhook_port 4_748

  defp serve(_options, task) when task != [] do
    {:error, "--serve does not accept a task"}
  end

  defp serve(options, []) do
    cond do
      Keyword.get(options, :setup, false) ->
        {:error, "choose either --serve or --setup, not both"}

      Keyword.has_key?(options, :resume) ->
        {:error, "--serve does not accept --resume"}

      true ->
        do_serve(options)
    end
  end

  defp do_serve(options) do
    with {:ok, config} <- load_config(options),
         {:ok, command_mode} <- command_mode(options),
         {:ok, base_options} <- serve_run_options(options, config, command_mode),
         {:ok, listener_specs} <- serve_listener_specs(config, options),
         {:ok, queue} <- start_serve_queue(config),
         registry_opts = serve_registry_opts(config, queue, base_options),
         {:ok, registry} <- Registry.start_link(registry_opts) do
      case start_serve_listeners(listener_specs, registry) do
        {:ok, descriptions} ->
          Enum.each(descriptions, &IO.puts(:stderr, "alto: " <> &1))
          IO.puts(:stderr, "alto: serving configuration as \"default\" (Ctrl-C to stop)")
          Process.sleep(:infinity)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Served-run session persistence (, explicit opt-in via the compiled
  # configuration's `sessions:` key: `true`, or `[session_dir: path]`).
  # Without it, served runs stay unpersisted; `session_dir:` alone selects
  # the directory resume reads from.
  defp serve_registry_opts(config, queue, base_options) do
    run_options = Config.run_options(config)

    [
      config_resolver: serve_resolver(base_options, Keyword.get(run_options, :runs, %{})),
      cwd: File.cwd!(),
      queue: queue,
      sessions: Keyword.get(run_options, :sessions) || false,
      session_dir: Keyword.get(run_options, :session_dir)
    ]
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp serve_resolver(base_options, named_runs) do
    fn
      "default" ->
        {:ok, base_options}

      other ->
        case Map.fetch(named_runs, other) do
          {:ok, overrides} -> {:ok, Keyword.merge(base_options, overrides)}
          :error -> {:error, {:unknown_config, other}}
        end
    end
  end

  # The durable queue behind the claim/ack surface (the integration contract): opt in
  # via the compiled configuration's `queue:` key (Alto.Queue start options).
  # Without it, the queue commands answer `unsupported`.
  defp start_serve_queue(config) do
    case Config.run_options(config) |> Keyword.get(:queue) do
      nil ->
        {:ok, nil}

      opts ->
        Alto.Queue.start_link(Keyword.put_new(opts, :name, Alto.Queue))
    end
  end

  defp serve_run_options(options, config, command_mode) do
    with {:ok, run_options} <- common_run_options(options, config, command_mode) do
      {:ok,
       run_options
       |> configure_serve_approval(options)
       |> Keyword.drop([
         :listeners,
         :queue,
         :runs,
         :sessions,
         :session_dir,
         :cwd,
         :event_sink,
         :session_id,
         :tool_context_metadata
       ])}
    end
  end

  defp configure_serve_approval(run_options, options) do
    if Keyword.get(options, :approve_all, false) do
      Keyword.put(run_options, :approval, AllowAll)
    else
      Keyword.put(run_options, :approval, SocketApproval)
    end
  end

  # Listener selection is compiled configuration, like executors and approval
  # policies: `listeners: [{Alto.Listeners.UnixSocket, path: "..."},
  # {Alto.Listeners.WebServer, port: 4747}]`. Without it, serve starts both
  # transports with flag overrides applied.
  defp serve_listener_specs(config, options) do
    specs =
      config
      |> Config.run_options()
      |> Keyword.get(:listeners, [{UnixSocket, []}, {WebServer, []}])

    specs = specs |> fill_listener_defaults() |> apply_listener_flags(options)

    with :ok <- validate_listener_ports(specs) do
      {:ok, specs}
    end
  end

  defp validate_listener_ports(specs) do
    ports =
      for {module, opts} <- specs, module in [WebServer, Webhook] do
        Keyword.fetch!(opts, :port)
      end

    if Enum.all?(ports, &(&1 in 0..65_535)) do
      :ok
    else
      {:error, "invalid listener port: want 0-65535"}
    end
  end

  defp fill_listener_defaults(specs) do
    Enum.map(specs, fn
      {UnixSocket, opts} -> {UnixSocket, Keyword.put_new(opts, :path, default_socket_path())}
      {WebServer, opts} -> {WebServer, Keyword.put_new(opts, :port, @default_serve_port)}
      {Webhook, opts} -> {Webhook, Keyword.put_new(opts, :port, @default_webhook_port)}
    end)
  end

  defp apply_listener_flags(specs, options) do
    specs
    |> override_listener(UnixSocket, :path, Keyword.get(options, :socket))
    |> override_listener(WebServer, :port, Keyword.get(options, :port))
  end

  defp override_listener(specs, _module, _key, nil), do: specs

  defp override_listener(specs, module, key, value) do
    if Enum.any?(specs, &match?({^module, _}, &1)) do
      Enum.map(specs, fn
        {^module, opts} -> {module, Keyword.put(opts, key, value)}
        other -> other
      end)
    else
      specs ++ [{module, [{key, value}]}]
    end
  end

  defp default_socket_path do
    state_home =
      System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")

    Path.join([state_home, "alto", "alto.sock"])
  end

  defp start_serve_listeners(specs, registry) do
    Alto.Result.traverse(specs, fn {module, opts} ->
      case module.start_link(Keyword.put(opts, :registry, registry)) do
        {:ok, listener} -> {:ok, describe_listener(module, opts, listener)}
        {:error, reason} -> {:error, format_reason(reason)}
      end
    end)
  end

  defp describe_listener(UnixSocket, opts, _listener),
    do: "listening on #{Path.expand(Keyword.fetch!(opts, :path))}"

  defp describe_listener(WebServer, _opts, listener),
    do:
      "serving WebSocket at #{WebServer.url(listener)} (token: #{WebServer.token(listener) || "none"})"

  defp describe_listener(Webhook, opts, listener) do
    paths =
      opts
      |> Keyword.fetch!(:endpoints)
      |> Enum.map(&"#{&1[:path]}")
      |> Enum.join(", ")

    "serving webhook endpoints at http://127.0.0.1:#{Webhook.bound_port(listener)} (#{paths})"
  end

  defp setup(options, []) do
    if Onboarding.terminal?() do
      case Onboarding.resolve(
             force: true,
             interactive: true,
             api_key: environment_api_key(options, :openrouter),
             provider: {OpenAICompatible, discovery_provider_options(options)}
           ) do
        {:ok, %{model: model}} ->
          IO.puts(:stderr, "OpenRouter setup complete. Default model: #{model}")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "--setup requires an interactive terminal"}
    end
  end

  defp setup(_options, task) when task != [], do: {:error, "--setup does not accept a task"}

  defp load_config(options) do
    explicit = Keyword.get(options, :config)
    disabled? = Keyword.get(options, :no_config, false)

    cond do
      disabled? and explicit ->
        {:error, "choose either --config or --no-config, not both"}

      disabled? ->
        {:ok, Config.new()}

      explicit ->
        Config.load(explicit)

      path = System.get_env("ALTO_CONFIG") ->
        Config.load(path)

      File.regular?(Config.default_path()) ->
        Config.load(Config.default_path())

      true ->
        {:ok, Config.new()}
    end
  end

  defp run_options(options, config, command_mode) do
    with {:ok, run_options} <- common_run_options(options, config, command_mode) do
      renderer = Renderer.start(Onboarding.terminal?())

      run_options =
        run_options
        |> configure_approval(options)
        |> configure_session(options)
        |> Keyword.put(:cwd, File.cwd!())
        |> Alto.Events.attach(&send(renderer, {:event, &1}))

      {:ok, run_options, renderer}
    end
  end

  defp common_run_options(options, config, command_mode) do
    configured = config |> Config.run_options() |> Keyword.drop([:tui])

    with {:ok, provider, provider_timeout} <- provider(options, configured) do
      {:ok,
       configured
       |> Keyword.put(:provider, provider)
       |> configure_provider_timeout(provider_timeout)
       |> configure_tools(options, command_mode)
       |> Keyword.merge(Keyword.take(options, [:max_steps]))
       |> configure_prompt(options)
       |> configure_project_instructions(options)}
    end
  end

  defp configure_project_instructions(run_options, options) do
    if Keyword.get(options, :no_project_instructions, false) do
      Keyword.put(run_options, :project_instructions, nil)
    else
      Keyword.put_new(run_options, :project_instructions, :auto)
    end
  end

  # One-shot runs persist by default so every run stays resumable; served
  # runs (built separately) and explicit opt-outs do not.
  defp configure_session(run_options, options) do
    if Keyword.get(options, :no_session, false) do
      Keyword.put(run_options, :session, nil)
    else
      Keyword.put(run_options, :session, :new)
    end
  end

  defp provider(options, configured) do
    # A provider key with a nil value is an explicit providerless profile. An
    # omitted key retains the default agent onboarding. CLI model/transport
    # switches are deliberate overrides and therefore opt back into provider
    # construction even for a providerless configuration.
    transport_override? = Enum.any?([:base_url, :api_key_env], &Keyword.has_key?(options, &1))

    cond do
      transport_override? ->
        configured_provider(options)

      Keyword.has_key?(configured, :provider) ->
        case Keyword.fetch!(configured, :provider) do
          nil ->
            if Keyword.has_key?(options, :model) do
              configured_provider(options)
            else
              {:ok, nil, provider_timeout(options)}
            end

          provider ->
            {:ok, patch_model(provider, options), provider_timeout(options)}
        end

      true ->
        configured_provider(options)
    end
  end

  # A model flag overrides only the model of a configured provider; transport
  # options and credentials chosen in the configuration stay intact.
  defp patch_model({module, opts}, options) when is_atom(module) and is_list(opts) do
    {module, patch_model_opts(opts, options)}
  end

  defp patch_model(module, options) when is_atom(module),
    do: {module, patch_model_opts([], options)}

  defp patch_model_opts(opts, options) do
    case requested_model(options) do
      model when is_binary(model) and model != "" -> Keyword.put(opts, :model, model)
      _other -> opts
    end
  end

  defp configured_provider(options) do
    base_url = base_url(options)
    timeout = Keyword.get(options, :timeout, 120_000)

    with {:ok, selected} <- select_provider(options, base_url) do
      provider_options = [
        model: selected.model,
        base_url: base_url,
        api_key: selected.api_key,
        timeout: timeout
      ]

      {:ok, {OpenAICompatible, provider_options}, timeout + 5_000}
    end
  end

  defp select_provider(options, base_url) do
    if openrouter?(base_url) do
      Onboarding.resolve(
        api_key: environment_api_key(options, :openrouter),
        model: requested_model(options),
        interactive: Onboarding.terminal?(),
        provider: {OpenAICompatible, discovery_provider_options(options, base_url)}
      )
    else
      with {:ok, model} <- required_model(options) do
        {:ok, %{model: model, api_key: environment_api_key(options, :compatible)}}
      end
    end
  end

  defp discovery_provider_options(options, base_url \\ "https://openrouter.ai/api/v1") do
    [
      base_url: base_url,
      timeout: Keyword.get(options, :timeout, 120_000),
      model_query: [supported_parameters: "tools", sort: "most-popular"]
    ]
  end

  defp provider_timeout(options) do
    if Keyword.has_key?(options, :timeout) do
      Keyword.fetch!(options, :timeout) + 5_000
    end
  end

  defp configure_provider_timeout(run_options, nil), do: run_options

  defp configure_provider_timeout(run_options, provider_timeout),
    do: Keyword.put(run_options, :provider_timeout, provider_timeout)

  defp configure_tools(run_options, options, command_mode) do
    if tool_flags?(options) or not Keyword.has_key?(run_options, :tools) do
      write_enabled? = Keyword.get(options, :allow_write, false)
      Keyword.put(run_options, :tools, tools(options, write_enabled?, command_mode))
    else
      run_options
    end
  end

  defp tool_flags?(options) do
    Enum.any?(
      [:no_tools, :allow_write, :allow_command, :sandbox_command, :allow_command_network],
      &Keyword.has_key?(options, &1)
    )
  end

  defp configure_approval(run_options, options) do
    cond do
      Keyword.get(options, :approve_all, false) -> Keyword.put(run_options, :approval, AllowAll)
      Keyword.has_key?(run_options, :approval) -> run_options
      true -> Keyword.put(run_options, :approval, Interactive)
    end
  end

  defp configure_prompt(run_options, options) do
    if prompt_flags?(options),
      do: Keyword.merge(run_options, prompt_options(options)),
      else: Keyword.put_new(run_options, :prompt, Alto.Prompts.Coding)
  end

  defp prompt_flags?(options) do
    Keyword.has_key?(options, :system_prompt) or Keyword.has_key?(options, :no_system_prompt)
  end

  defp required_model(options) do
    case requested_model(options) do
      model when is_binary(model) and model != "" -> {:ok, model}
      _other -> {:error, "set --model or ALTO_MODEL"}
    end
  end

  defp requested_model(options), do: Keyword.get(options, :model) || System.get_env("ALTO_MODEL")

  defp task_text([]) do
    if Onboarding.terminal?() do
      {:error, "no task provided; pass a task as arguments or pipe one on stdin (see --help)"}
    else
      case IO.read(:stdio, :eof) do
        task when is_binary(task) and task != "" -> {:ok, task}
        _other -> {:error, "no task provided; pass a task as arguments or pipe one on stdin"}
      end
    end
  end

  defp task_text(words), do: {:ok, Enum.join(words, " ")}

  defp base_url(options) do
    Keyword.get(options, :base_url) ||
      System.get_env("ALTO_BASE_URL") ||
      System.get_env("OPENROUTER_BASE_URL") ||
      System.get_env("OPENAI_BASE_URL") ||
      "https://openrouter.ai/api/v1"
  end

  defp environment_api_key(options, provider) do
    case Keyword.get(options, :api_key_env) do
      name when is_binary(name) ->
        System.get_env(name)

      _other when provider == :openrouter ->
        System.get_env("ALTO_API_KEY") || System.get_env("OPENROUTER_API_KEY")

      _other ->
        System.get_env("ALTO_API_KEY") || System.get_env("OPENAI_API_KEY")
    end
  end

  defp openrouter?(base_url) do
    case URI.parse(base_url) do
      %URI{host: "openrouter.ai"} -> true
      %URI{host: host} when is_binary(host) -> String.ends_with?(host, ".openrouter.ai")
      _other -> false
    end
  end

  defp tools(options, write_enabled?, command_mode) do
    if Keyword.get(options, :no_tools, false) do
      []
    else
      [ListFiles, ReadFile, SearchFiles] ++
        if(write_enabled?,
          do: Enum.map([EditFile, WriteFile], &Alto.Tools.ProtectPaths.wrap(&1, [".git"])),
          else: []
        ) ++
        command_tools(command_mode, options)
    end
  end

  defp command_mode(options) do
    unsandboxed? = Keyword.get(options, :allow_command, false)
    sandboxed? = Keyword.get(options, :sandbox_command, false)
    network? = Keyword.get(options, :allow_command_network, false)

    cond do
      unsandboxed? and sandboxed? ->
        {:error, "choose either --allow-command or --sandbox-command, not both"}

      network? and not sandboxed? ->
        {:error, "--allow-command-network requires --sandbox-command"}

      sandboxed? ->
        {:ok, :sandboxed}

      unsandboxed? ->
        {:ok, :unsandboxed}

      true ->
        {:ok, :disabled}
    end
  end

  defp command_tools(:disabled, _options), do: []
  defp command_tools(:unsandboxed, _options), do: [RunCommand]

  defp command_tools(:sandboxed, options) do
    network =
      if Keyword.get(options, :allow_command_network, false), do: :inherit, else: :disabled

    [
      {RunCommand,
       executor: {Alto.Command.Executors.Bubblewrap, network: network, protected_paths: [".git"]}}
    ]
  end

  defp prompt_options(options) do
    cond do
      Keyword.get(options, :no_system_prompt, false) -> [prompt: nil]
      prompt = Keyword.get(options, :system_prompt) -> [prompt: prompt]
      true -> []
    end
  end

  defp format_reason({:http_error, status, detail}),
    do: "provider returned HTTP #{status}: #{inspect(detail)}"

  defp format_reason({:socket_bind_failed, path, :already_in_use}),
    do: "socket #{path} is already served by another Alto process"

  defp format_reason({:socket_bind_failed, path, reason}),
    do: "could not bind socket #{path}: #{inspect(reason)}"

  defp format_reason({:listen_failed, reason}),
    do: "could not listen for the WebSocket: #{inspect(reason)}"

  defp format_reason({:config_load_failed, path, reason}),
    do: "could not load config #{path}: #{inspect(reason)}"

  defp format_reason({:invalid_config_return, path}),
    do: "config #{path} must return %Alto.Config{}"

  defp format_reason({:session_not_found, id}), do: "no such session #{id}"

  defp format_reason(:no_resumable_transcript),
    do: "session has no completed run to resume from (it may have crashed mid-run)"

  defp format_reason({:invalid_session_id, id}), do: "invalid session id #{inspect(id)}"

  defp format_reason({:session_corrupt, id, line}),
    do: "session #{id} is corrupt near record #{inspect(line)}"

  defp format_reason({:session_read_failed, reason}),
    do: "could not read sessions: #{inspect(reason)}"

  defp format_reason({:transcript_limit, max}),
    do: "transcript exceeded #{max} bytes (set compaction: true to compact and continue)"

  defp format_reason(:compaction_requires_session),
    do: "transcript limit reached, but compaction needs a session (drop --no-session)"

  defp format_reason(:compaction_requires_provider),
    do: "transcript limit reached, but compaction needs a provider"

  defp format_reason(reason), do: inspect(reason, pretty: true, limit: 20)
end
