defmodule Alto.TUI.Backends.Native do
  @moduledoc "Native Alto runner with catalog-session resume."
  @behaviour Alto.TUI.Backend
  @impl true
  def ui(event, _state, _options) when event in [:steering?, :session_usage?], do: true
  def ui(_event, _state, _options), do: :pass
  alias Alto.Session
  @impl true
  def start(task, prompt, run_options, _options) do
    case task["conversation_id"] do
      conversation_id when is_binary(conversation_id) ->
        with {:ok, resume_opts} <- Session.resume_options(conversation_id, run_options),
             do: Alto.start(prompt, Keyword.merge(run_options, resume_opts))

      _none ->
        Alto.start(prompt, Keyword.put(run_options, :session, :new))
    end
  end

  @impl true
  def cancel(%{handle: handle}, reason, _options), do: Alto.cancel(handle, reason)
end
