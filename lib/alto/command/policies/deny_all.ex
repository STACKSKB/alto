defmodule Alto.Command.Policies.DenyAll do
  @moduledoc "Command policy that refuses every invocation."

  @behaviour Alto.Command.Policy

  @impl true
  def prepare(_arguments, _context, opts) do
    {:error, Keyword.get(opts, :reason, :commands_disabled)}
  end
end
