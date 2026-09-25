defmodule Alto.TUI.Backend do
  @moduledoc """
  Host-composed terminal backends. `tui_backends` is the complete ordered list;
  identifiers, including `:alto` and `:codex`, are not reserved.

  Runner adapters implement `start/4` and `cancel/3`. Interactive adapters
  implement `ui/3` and `cancel/3`, owning their connection and protocol lifecycle.
  Optional UI contributions receive `:prepare`, `:selected`, `:model`,
  `:steering?`, `:session_usage?`,
  `{:submit, prompt}`, `{:overlay, kind}`, `{:select, value}` and
  `{:message, message}`. Return `:pass` to use ordinary terminal behavior.
  Message contributions use the application's `handle_info` return contract;
  overlay contributions return picker items or `{:state, state}`.

  Adapters keep their private UI state in `state.backend_state`, keyed by their
  module. Initialization must preserve other adapters' entries. The host neither
  interprets these values nor reserves a state field for built-in adapters.

  These are trusted host components. Runner adapters must honor the supplied
  approval policy and runtime limits. Interactive adapters own their protocol's
  equivalent controls and put their cancellation adapter on each active run.
  """
  @callback start(map(), String.t(), keyword(), keyword()) ::
              {:ok, Alto.Runner.Handle.t()} | {:error, term()}
  @callback cancel(map(), term(), keyword()) :: term()
  @callback ui(term(), map(), keyword()) :: term()
  @optional_callbacks start: 4, ui: 3

  def configured(options), do: Keyword.get(options, :tui_backends, [])

  def lookup(options, id) do
    case Keyword.fetch(configured(options), id) do
      {:ok, {module, opts}} -> {:ok, module, opts}
      :error -> {:error, {:backend_unavailable, id}}
    end
  end

  def runner?(options, id) do
    case lookup(options, id) do
      {:ok, module, _opts} -> function_exported?(module, :start, 4)
      _ -> false
    end
  end

  def items(options) do
    Enum.map(configured(options), fn {id, {_module, opts}} ->
      %{label: Keyword.get(opts, :label, Atom.to_string(id)), value: id}
    end)
  end

  def ui(state, event) do
    case lookup(state.run_options, state.selected_backend) do
      {:ok, module, opts} -> contribution(module, event, state, opts)
      _ -> :pass
    end
  end

  def initialize(state) do
    Enum.reduce(configured(state.run_options), state, fn {_id, {module, opts}}, acc ->
      case contribution(module, :init, acc, opts) do
        :pass -> acc
        next -> next
      end
    end)
  end

  def message(state, message) do
    Enum.reduce_while(configured(state.run_options), :pass, fn {_id, {module, opts}}, :pass ->
      case contribution(module, {:message, message}, state, opts) do
        :pass -> {:cont, :pass}
        result -> {:halt, result}
      end
    end)
  end

  defp contribution(module, event, state, opts) do
    if function_exported?(module, :ui, 3), do: module.ui(event, state, opts), else: :pass
  end

  def valid?(backends) when is_list(backends) do
    Keyword.keyword?(backends) and
      length(Keyword.keys(backends)) == length(Enum.uniq(Keyword.keys(backends))) and
      Enum.all?(backends, fn
        {id, {module, opts}} when is_atom(module) and is_list(opts) ->
          Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, Atom.to_string(id)) and
            Keyword.keyword?(opts) and Code.ensure_loaded?(module) and
            function_exported?(module, :cancel, 3) and
            (function_exported?(module, :start, 4) or function_exported?(module, :ui, 3))

        _ ->
          false
      end)
  end

  def valid?(_), do: false
end
