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
    :codex_backend,
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
  @tui_schema NimbleOptions.new!(@tui_options)
  @enforce_keys [:run_options]
  defstruct [:run_options]

  @type t :: %__MODULE__{run_options: keyword()}

  @doc "Build a configuration from options accepted by `Alto.run/2`."
  @spec new(keyword()) :: t()
  def new(run_options \\ [])

  def new(run_options) do
    validate_keys!(run_options, @allowed_options, "Alto")
    validate_tui_options!(Keyword.get(run_options, :tui, []))
    %__MODULE__{run_options: run_options}
  end

  defp validate_keys!(options, allowed, label) do
    unless is_list(options) and Keyword.keyword?(options),
      do: raise(ArgumentError, "#{label} configuration must be a keyword list")

    keys = Keyword.keys(options)
    unknown = Enum.reject(keys, &(&1 in allowed)) |> Enum.uniq()

    cond do
      unknown != [] ->
        raise ArgumentError, "unknown #{label} configuration options: #{inspect(unknown)}"

      length(keys) != MapSet.size(MapSet.new(keys)) ->
        raise ArgumentError, "#{label} configuration options must be unique"

      true ->
        :ok
    end
  end

  defp validate_tui_options!(options) do
    validate_keys!(options, Keyword.keys(@tui_options), "Alto TUI")

    case NimbleOptions.validate(options, @tui_schema) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        raise ArgumentError, "Alto TUI #{Exception.message(error)}"
    end
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
