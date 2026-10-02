defmodule Alto.Contrib.CacheWarmer do
  @moduledoc """
  Opt-in native Anthropic cache maintenance while root tools are running.

  `start(task, run_options, warmer_options)` returns an ordinary Alto handle;
  `run/3` waits for it. Warming stops at completion/cancellation, owner death,
  the configured horizon, a cache miss or an error. Children and context
  reduction do not replace the root request. Nothing is enabled by `configure/1`.

  Refreshes replay the last successful normal request with `max_tokens: 0`
  and `stream: false`; tools, messages and cache-sensitive options are retained.
  Unsupported thinking, structured output and forced-tool requests are skipped.
  This is best effort: eviction and minimum prompt sizes can still cause misses.

  Options (all positive integers): `max_requests` (3), `max_duration_ms`
  (900_000), `request_timeout_ms` (10_000), `refresh_margin_ms` (30_000),
  `max_prompt_bytes` (1_000_000). Limits apply across this run, including failures.
  Requests are additional to core model budgets and may bill input even on a miss.
  `:cache_warm_finished` live events report separate canonical usage; warming
  never adds model steps, conversation messages, or executes returned tools.
  Hosts requiring aggregate billing should include these events in their ledger.

  Native protocol: https://platform.claude.com/docs/en/build-with-claude/prompt-caching#pre-warming-the-cache
  """
  alias Alto.Contrib.CacheWarmer.Server
  alias Alto.Contrib.Providers.Anthropic

  @schema [
    max_requests: [type: :pos_integer, default: 3],
    max_duration_ms: [type: :pos_integer, default: 900_000],
    request_timeout_ms: [type: :pos_integer, default: 10_000],
    refresh_margin_ms: [type: :pos_integer, default: 30_000],
    max_prompt_bytes: [type: :pos_integer, default: 1_000_000]
  ]

  def run(task, options, warmer_options \\ []) do
    case start(task, Keyword.put_new(options, :owner, self()), warmer_options) do
      {:ok, handle} ->
        try do
          Alto.await(handle)
        after
          Alto.Runner.release(handle)
        end

      {:error, reason} ->
        Alto.Runner.Result.error(reason)
    end
  end

  def start(task, options, warmer_options \\ []) do
    with {:ok, settings} <- NimbleOptions.validate(warmer_options, @schema),
         {:ok, provider_options} <- native_provider(options[:provider]) do
      run_id =
        options[:session_id] ||
          "warm-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

      owner = Keyword.get(options, :owner)
      sink = options[:event_sink]
      settings = Map.new(settings)

      args =
        Map.merge(settings, %{
          run_id: run_id,
          owner: owner,
          sink: sink,
          plan: &Anthropic.cache_warm_plan(&1, Alto.Provider.options(provider_options)),
          refresh: &Anthropic.warm_cache/2
        })

      with {:ok, server} <- Server.start(args) do
        observed =
          Alto.Provider.observe({Anthropic, provider_options}, &Server.request(server, &1))

        opts =
          options
          |> Keyword.put(:provider, observed)
          |> Keyword.put(:session_id, run_id)
          |> Keyword.put(:owner, owner)
          |> Keyword.put(:event_sink, fn event ->
            Server.event(server, event)
            Alto.Events.notify(sink, event)
          end)

        case start_run(task, opts, server) do
          {:ok, handle} ->
            case Alto.Runner.subscribe(handle, server) do
              {:ok, ref} ->
                Server.subscribe(server, ref)
                {:ok, handle}

              {:error, reason} ->
                Server.stop(server)
                Alto.cancel(handle, reason)
                {:error, reason}
            end

          error ->
            Server.stop(server)
            error
        end
      end
    else
      {:error, _} = error -> error
    end
  end

  defp native_provider(Anthropic), do: {:ok, []}

  defp native_provider({Anthropic, opts}) when is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, opts}, else: {:error, :invalid_provider_options}
  end

  defp native_provider(_), do: {:error, :cache_warming_requires_native_anthropic}

  defp start_run(task, opts, server) do
    Alto.Contrib.start(task, opts)
  catch
    kind, reason ->
      Server.stop(server)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end
end
