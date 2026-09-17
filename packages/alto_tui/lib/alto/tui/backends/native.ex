defmodule Alto.TUI.Backends.Native do
  @moduledoc "Native Alto runner with catalog-session resume."
  @behaviour Alto.TUI.Backend
  @impl true
  def ui(:durable_input?, _state, _options), do: true
  def ui(_event, _state, _options), do: :pass
  alias Alto.Session
  @impl true
  def start(task, prompt, run_options, _options) do
    case task["session_id"] do
      session_id when is_binary(session_id) ->
        session_opts = Keyword.take(run_options, [:session_dir])

        with {:ok, snapshot} <- Session.transcript(session_id, session_opts) do
          run_options =
            run_options
            |> Keyword.put(:session, session_id)
            |> Keyword.put(
              :resume,
              Map.take(snapshot, [:messages, :transcript_bytes, :revision, :context_observation])
            )

          Alto.start(prompt, run_options)
        end

      _none ->
        Alto.start(prompt, Keyword.put(run_options, :session, :new))
    end
  end

  @impl true
  def cancel(handle, reason, _options), do: Alto.cancel(handle, reason)
end
