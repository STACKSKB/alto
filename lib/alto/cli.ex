defmodule Alto.CLI do
  @moduledoc "Plain-stdio command-line entry point for the execution host."

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
  alias Alto.Tools.ListFiles
  alias Alto.Tools.ReadFile
  alias Alto.Tools.SearchFiles

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
         {:ok, run_options, renderer} <- run_options(options, config) do
      try do
        result =
          case run_task(options, task, run_options) do
            {:error, reason} -> Alto.Runner.Result.error(reason)
            result -> result
          end

        status =
          if match?(%Alto.Runner.Result{status: :ok}, result),
            do: :ok,
            else: {:error, result.reason}

        rendered = Renderer.stop(renderer)
        if status == :ok, do: Renderer.finish(result.output, rendered)
        IO.write("\n")
        report_session(result.session_id)
        status
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
              "  last:#{summary.last_status || "-"}  #{summary.task || ""}"
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
  ## so approval defaults to `Alto.Approvals.Socket`; compiled policies are honored.

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
         {:ok, base_options} <- serve_run_options(config),
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

  # Served-run session persistence is an explicit opt-in via the compiled
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

  defp serve_run_options(config) do
    with {:ok, run_options} <- common_run_options(config) do
      {:ok,
       run_options
       |> Keyword.put_new(:approval, SocketApproval)
       |> Keyword.drop([
         :listeners,
         :queue,
         :runs,
         :sessions,
         :session_dir,
         :event_sink,
         :session_id,
         :tool_context_metadata
       ])}
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

    defaults = %{
      UnixSocket => [path: default_socket_path()],
      WebServer => [port: @default_serve_port],
      Webhook => [port: @default_webhook_port]
    }

    overrides =
      for {module, key, value} <- [
            {UnixSocket, :path, options[:socket]},
            {WebServer, :port, options[:port]}
          ],
          not is_nil(value),
          do: {module, [{key, value}]}

    specs =
      Enum.map(specs, fn {module, opts} ->
        opts = Keyword.merge(Map.get(defaults, module, []), opts)
        {module, Keyword.merge(opts, Keyword.get(overrides, module, []))}
      end)

    specs = specs ++ Enum.reject(overrides, &List.keymember?(specs, elem(&1, 0), 0))

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

  defp default_socket_path do
    Path.join([Alto.Storage.state_home(), "alto", "alto.sock"])
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
      |> Map.keys()
      |> Enum.sort()
      |> Enum.join(", ")

    "serving webhook endpoints at http://127.0.0.1:#{Webhook.bound_port(listener)} (#{paths})"
  end

  defp describe_listener(module, _opts, _listener), do: "started listener #{inspect(module)}"

  defp setup(_options, []) do
    if Onboarding.terminal?() do
      case Onboarding.resolve(
             force: true,
             interactive: true,
             api_key: environment_api_key(),
             provider: {OpenAICompatible, default_provider_options()}
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

  defp run_options(options, config) do
    with {:ok, run_options} <- common_run_options(config) do
      renderer = Renderer.start(Onboarding.terminal?())

      run_options =
        run_options
        |> Keyword.put_new(:approval, Interactive)
        |> configure_session(options)
        |> Keyword.put_new(:cwd, File.cwd!())
        |> Alto.Events.attach(&send(renderer, {:event, &1}))

      {:ok, run_options, renderer}
    end
  end

  defp common_run_options(config) do
    configured = config |> Config.run_options() |> Keyword.drop([:tui])

    provider =
      case Keyword.fetch(configured, :provider) do
        {:ok, provider} -> {:ok, provider}
        :error -> default_provider()
      end

    with {:ok, provider} <- provider do
      {:ok,
       configured
       |> Keyword.put(:provider, provider)
       |> Keyword.put_new(:tools, [ListFiles, ReadFile, SearchFiles])
       |> Keyword.put_new(:prompt, if(provider, do: &Alto.Prompts.Coding.build/1))
       |> Keyword.put_new(:project_instructions, :auto)}
    end
  end

  # One-shot runs persist by default so every run stays resumable; served
  # runs (built separately) and explicit opt-outs do not.
  defp configure_session(run_options, options) do
    if Keyword.get(options, :no_session, false) do
      Keyword.put(run_options, :session, nil)
    else
      Keyword.put_new(run_options, :session, :new)
    end
  end

  defp default_provider do
    options = default_provider_options()

    with {:ok, selected} <-
           Onboarding.resolve(
             api_key: environment_api_key(),
             model: System.get_env("ALTO_MODEL"),
             interactive: Onboarding.terminal?(),
             provider: {OpenAICompatible, options}
           ) do
      {:ok,
       {OpenAICompatible,
        Keyword.merge(options, model: selected.model, api_key: selected.api_key)}}
    end
  end

  defp default_provider_options do
    [
      base_url: "https://openrouter.ai/api/v1",
      timeout: 120_000,
      model_query: [supported_parameters: "tools", sort: "most-popular"]
    ]
  end

  defp environment_api_key,
    do: System.get_env("ALTO_API_KEY") || System.get_env("OPENROUTER_API_KEY")

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

  defp format_reason({:socket_bind_failed, path, :already_in_use}),
    do: "socket #{path} is already served by another Alto process"

  defp format_reason({:invalid_config_return, path}),
    do: "config #{path} must return %Alto.Config{}"

  defp format_reason({:session_not_found, id}), do: "no such session #{id}"

  defp format_reason(:no_resumable_transcript),
    do: "session has no completed run to resume from (it may have crashed mid-run)"

  defp format_reason({:invalid_session_id, id}), do: "invalid session id #{inspect(id)}"

  defp format_reason({:transcript_limit, max}),
    do: "transcript exceeded #{max} bytes (set compaction: true to compact and continue)"

  defp format_reason(:compaction_requires_session),
    do: "transcript limit reached, but compaction needs a session (drop --no-session)"

  defp format_reason(:compaction_requires_provider),
    do: "transcript limit reached, but compaction needs a provider"

  defp format_reason(reason), do: Alto.Display.error(reason)
end
