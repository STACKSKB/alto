defmodule Alto.TUI.Backend do
  @moduledoc """
  Additional local execution backends for the terminal.

  Configure `tui_backends: [custom: {MyBackend, options}]`. The adapter accepts
  the same trusted run options (including event sink and approval policy),
  returns a serial-compatible supervised task handle, and supports cancellation.
  Its task must return an `Alto.Runner.Serial.Result` outcome. It owns resume
  semantics using the supplied catalog task. A configured adapter is trusted
  code and must enforce the supplied approval policy and runtime limits.
  The built-in Codex integration retains its account-specific UI.
  """

  @callback start(map(), String.t(), keyword(), keyword()) ::
              {:ok, Alto.Runner.Serial.Handle.t()} | {:error, term()}
  @callback cancel(Alto.Runner.Serial.Handle.t(), term(), keyword()) :: term()

  def configured(options), do: Keyword.get(options, :tui_backends, [])

  def lookup(options, id) do
    case Keyword.fetch(configured(options), id) do
      {:ok, {module, opts}} -> {:ok, module, opts}
      :error -> {:error, {:backend_unavailable, id}}
    end
  end

  def items(options) do
    [%{label: "Alto native", value: :alto}, %{label: "Codex · ChatGPT", value: :codex}] ++
      Enum.map(configured(options), fn {id, _spec} -> %{label: Atom.to_string(id), value: id} end)
  end

  def valid?(backends) when is_list(backends) do
    Keyword.keyword?(backends) and
      length(Keyword.keys(backends)) == length(Enum.uniq(Keyword.keys(backends))) and
      Enum.all?(backends, fn
        {id, {module, opts}}
        when id not in [:alto, :codex] and is_atom(module) and is_list(opts) ->
          Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, Atom.to_string(id)) and
            Keyword.keyword?(opts) and
            Code.ensure_loaded?(module) and function_exported?(module, :start, 4) and
            function_exported?(module, :cancel, 3)

        _ ->
          false
      end)
  end

  def valid?(_), do: false
end
