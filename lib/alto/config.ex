defmodule Alto.Config do
  @moduledoc """
  Trusted, compiled Elixir configuration for an Alto run.

  A configuration file evaluates to this struct. The CLI owns its working
  directory, renderer, and cancellation handle; configuration composes the
  loop, provider, tools, prompt, approval policy, and bounded runner options.
  """

  @allowed_options [
    :runner,
    :runner_options,
    :input,
    :loop,
    :provider,
    :provider_profiles,
    :tools,
    :model_tools,
    :approval,
    :checkpoint_version,
    :continuation_store,
    :prompt,
    :project_instructions,
    :max_steps,
    :max_effects,
    :budget_account,
    :max_model_requests,
    :run_timeout,
    :provider_timeout,
    :tool_timeout,
    :approval_timeout,
    :max_approval_details_bytes,
    :max_tool_result_bytes,
    :max_transcript_bytes,
    :max_conversation_bytes,
    :max_events,
    :listeners,
    :queue,
    :runs,
    :sessions,
    :session_history,
    :session_dir,
    :compaction,
    :provider_retries,
    :retry_policy,
    :event_sink,
    :tool_presenter,
    :tui,
    :tui_backends
  ]

  @tui_options [
    type_to_compose: [type: :boolean],
    narrow_context: [type: {:in, [:adaptive, :drawer, :fullscreen]}],
    narrow_context_width: [type: {:in, 40..100}],
    narrow_context_fullscreen_below: [type: {:in, 0..300}],
    approval_auto_open: [type: :boolean]
  ]
  @schema NimbleOptions.new!(
            Keyword.merge(Enum.map(@allowed_options, &{&1, [type: :any]}),
              tui: [type: :keyword_list, keys: @tui_options],
              sessions: [
                type: {:or, [nil, :boolean, {:keyword_list, session_dir: [type: :string]}]}
              ],
              queue: [type: {:or, [nil, :keyword_list]}],
              runs: [type: {:map, :string, :keyword_list}],
              listeners: [
                type:
                  {:list,
                   {:tuple,
                    [
                      {:in,
                       [
                         Alto.Listeners.UnixSocket,
                         Alto.Listeners.WebServer,
                         Alto.Listeners.Webhook
                       ]},
                      :keyword_list
                    ]}}
              ]
            )
          )
  @enforce_keys [:run_options]
  defstruct [:run_options]

  @type t :: %__MODULE__{run_options: keyword()}

  @doc "Build a configuration from options accepted by `Alto.run/2`."
  @spec new(keyword()) :: t()
  def new(run_options \\ [])

  def new(run_options) do
    validate_unique!(run_options, "Alto")
    validate_unique!(Keyword.get(run_options, :tui, []), "Alto TUI")
    %__MODULE__{run_options: NimbleOptions.validate!(run_options, @schema)}
  end

  defp validate_unique!(options, label) do
    unless Keyword.keyword?(options),
      do: raise(ArgumentError, "#{label} configuration must be a keyword list")

    keys = Keyword.keys(options)

    if length(keys) != MapSet.size(MapSet.new(keys)),
      do: raise(ArgumentError, "#{label} configuration options must be unique")
  end

  @doc "Return the validated runner options stored in a configuration."
  @spec run_options(t()) :: keyword()
  def run_options(%__MODULE__{run_options: run_options}), do: run_options

  @doc "Evaluate a trusted Elixir configuration file."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    expanded = Path.expand(path)

    try do
      case Code.eval_file(expanded) do
        {%__MODULE__{run_options: run_options}, _binding} ->
          {:ok, new(run_options)}

        {_other, _binding} ->
          {:error, {:invalid_config_return, expanded}}
      end
    rescue
      error -> {:error, {:config_load_failed, expanded, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:config_load_failed, expanded, {kind, reason}}}
    end
  end

  @doc "Return the per-user configuration path without creating it."
  @spec default_path() :: Path.t()
  def default_path do
    config_home =
      case System.get_env("XDG_CONFIG_HOME") do
        path when is_binary(path) and path != "" -> path
        _other -> Path.join(System.user_home!(), ".config")
      end

    Path.join([config_home, "alto", "config.exs"])
  end
end
