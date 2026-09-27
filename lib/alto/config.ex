defmodule Alto.Config do
  @moduledoc """
  Trusted, compiled Elixir configuration for an Alto run.

  A configuration file evaluates to a keyword list. The CLI owns its renderer and
  cancellation handle; configuration composes the working directory,
  loop, provider, tools, prompt, approval policy, and bounded runner options.
  """

  @authority_limits [
    max_steps: [type: :pos_integer, default: 32],
    provider_timeout: [type: :pos_integer, default: 125_000],
    tool_timeout: [type: :pos_integer, default: 125_000],
    approval_timeout: [type: :pos_integer, default: 300_000],
    max_approval_details_bytes: [type: :pos_integer, default: 64_000],
    max_tool_result_bytes: [type: :pos_integer, default: 64_000],
    max_transcript_bytes: [type: :pos_integer, default: 8_000_000],
    max_events: [type: :pos_integer, default: 1_000]
  ]
  @execution_limits @authority_limits ++
                      [
                        provider_retries: [type: :non_neg_integer, default: 0],
                        agent_depth: [type: :non_neg_integer, default: 0],
                        resume_snapshot: [type: :boolean, default: true],
                        session_history: [
                          type: {:in, [:completed, :settled]},
                          default: :completed
                        ],
                        max_conversation_bytes: [type: :pos_integer, default: 128_000_000]
                      ]

  @doc false
  def execution_limits, do: @execution_limits
  @doc false
  def authority_fields, do: Keyword.keys(@authority_limits) ++ [:max_agent_depth]

  @doc "Evaluate a trusted Elixir configuration file."
  @spec load(Path.t()) :: {:ok, keyword()} | {:error, term()}
  def load(path) when is_binary(path) do
    expanded = Path.expand(path)

    try do
      {options, _binding} = Code.eval_file(expanded)

      if Keyword.keyword?(options),
        do: {:ok, options},
        else: {:error, {:invalid_config_return, expanded}}
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
