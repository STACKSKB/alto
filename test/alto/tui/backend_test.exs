defmodule Alto.TUI.BackendTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.Backend

  defmodule Interactive do
    @behaviour Backend
    def cancel(run, reason, opts), do: send(opts[:owner], {:cancelled, run, reason})
    def ui(:init, state, _opts), do: Map.put(state, :initialized, true)
    def ui(:provider_label, _state, opts), do: opts[:label]

    def ui({:message, :custom_message}, state, _opts),
      do: {:noreply, Map.put(state, :received, true)}

    def ui({:overlay, :model}, state, _opts), do: {:state, Map.put(state, :custom_overlay, true)}
    def ui(_event, _state, _opts), do: :pass
  end

  test "the configured list is complete and built-in identities are replaceable" do
    assert Backend.items([]) == []
    assert Backend.lookup([], :alto) == {:error, {:backend_unavailable, :alto}}
    options = [tui_backends: [alto: {Interactive, label: "Host backend"}]]
    assert Backend.valid?(options[:tui_backends])
    assert Backend.items(options) == [%{label: "Host backend", value: :alto}]
    assert Backend.lookup(options, :codex) == {:error, {:backend_unavailable, :codex}}
  end

  test "custom interactive contributions use the same dispatch as built-ins" do
    state = %{
      run_options: [tui_backends: [host: {Interactive, label: "Host"}]],
      selected_backend: :host
    }

    assert Backend.initialize(state).initialized
    assert Backend.ui(state, :provider_label) == "Host"
    assert {:state, %{custom_overlay: true}} = Backend.ui(state, {:overlay, :model})
    assert {:noreply, %{received: true}} = Alto.TUI.App.handle_info(:custom_message, state)
    assert Backend.message(state, :unknown) == :pass
    assert Backend.ui(state, :unknown) == :pass
  end

  test "native capability is associated with its implementation, not its identifier" do
    state = %{
      run_options: [tui_backends: [local: {Alto.TUI.Backends.Native, []}]],
      selected_backend: :local
    }

    assert Backend.valid?(state.run_options[:tui_backends])
    assert Backend.ui(state, :durable_input?)
    refute Backend.ui(%{state | selected_backend: :alto}, :durable_input?) == true
  end
end
