defmodule Alto.Contrib.Config do
  @moduledoc "Trusted application configuration files and user paths."
  defdelegate default(overrides \\ []), to: Alto.Config

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
