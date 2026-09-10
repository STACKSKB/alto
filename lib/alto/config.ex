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
    :loop,
    :provider,
    :provider_options,
    :provider_profiles,
    :codex_backend,
    :tools,
    :model_tools,
    :approval,
    :checkpoint_version,
    :prompt,
    :system_prompt,
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
    :max_events,
    :listeners,
    :queue,
    :runs,
    :sessions,
    :session_dir,
    :compaction,
    :provider_retries,
    :tui,
    :tui_backends
  ]

  @allowed_tui_options [
    :type_to_compose,
    :narrow_context,
    :narrow_context_width,
    :narrow_context_fullscreen_below,
    :approval_auto_open
  ]

  @enforce_keys [:run_options]
  defstruct [:run_options]

  @type t :: %__MODULE__{run_options: keyword()}

  @doc "Build a configuration from options accepted by `Alto.run/2`."
  @spec new(keyword()) :: t()
  def new(run_options \\ [])

  def new(run_options) when is_list(run_options) do
    unless Keyword.keyword?(run_options) do
      raise ArgumentError, "Alto configuration must be a keyword list"
    end

    keys = Keyword.keys(run_options)
    unknown = Enum.reject(keys, &(&1 in @allowed_options)) |> Enum.uniq()

    cond do
      unknown != [] ->
        raise ArgumentError, "unknown Alto configuration options: #{inspect(unknown)}"

      length(keys) != MapSet.size(MapSet.new(keys)) ->
        raise ArgumentError, "Alto configuration options must be unique"

      true ->
        validate_tui_options!(Keyword.get(run_options, :tui, []))
        %__MODULE__{run_options: run_options}
    end
  end

  def new(_other), do: raise(ArgumentError, "Alto configuration must be a keyword list")

  defp validate_tui_options!(options) when is_list(options) do
    unless Keyword.keyword?(options) do
      raise ArgumentError, "Alto TUI configuration must be a keyword list"
    end

    keys = Keyword.keys(options)
    unknown = Enum.reject(keys, &(&1 in @allowed_tui_options)) |> Enum.uniq()

    cond do
      unknown != [] ->
        raise ArgumentError, "unknown Alto TUI configuration options: #{inspect(unknown)}"

      length(keys) != MapSet.size(MapSet.new(keys)) ->
        raise ArgumentError, "Alto TUI configuration options must be unique"

      not is_boolean(Keyword.get(options, :type_to_compose, true)) ->
        raise ArgumentError, "Alto TUI :type_to_compose must be a boolean"

      Keyword.get(options, :narrow_context, :adaptive) not in [:adaptive, :drawer, :fullscreen] ->
        raise ArgumentError,
              "Alto TUI :narrow_context must be :adaptive, :drawer, or :fullscreen"

      not valid_integer_range?(Keyword.get(options, :narrow_context_width, 75), 40, 100) ->
        raise ArgumentError, "Alto TUI :narrow_context_width must be an integer from 40 to 100"

      not valid_integer_range?(
        Keyword.get(options, :narrow_context_fullscreen_below, 72),
        0,
        300
      ) ->
        raise ArgumentError,
              "Alto TUI :narrow_context_fullscreen_below must be an integer from 0 to 300"

      not is_boolean(Keyword.get(options, :approval_auto_open, true)) ->
        raise ArgumentError, "Alto TUI :approval_auto_open must be a boolean"

      true ->
        :ok
    end
  end

  defp validate_tui_options!(_other),
    do: raise(ArgumentError, "Alto TUI configuration must be a keyword list")

  defp valid_integer_range?(value, low, high),
    do: is_integer(value) and value >= low and value <= high

  @doc "Return the validated runner options stored in a configuration."
  @spec run_options(t()) :: keyword()
  def run_options(%__MODULE__{run_options: run_options}), do: run_options

  @doc "Classify whether provider selection is explicit or uses the CLI default."
  @spec provider_mode(t()) :: :default | :none | {:configured, term()}
  def provider_mode(%__MODULE__{run_options: run_options}) do
    case Keyword.fetch(run_options, :provider) do
      :error -> :default
      {:ok, nil} -> :none
      {:ok, provider} -> {:configured, provider}
    end
  end

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
