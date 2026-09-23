defmodule Alto.TUI.BackendTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.Backend

  defmodule Interactive do
    @behaviour Backend
    def cancel(run, reason, opts), do: send(opts[:owner], {:cancelled, run, reason})
    def ui(:init, state, _opts), do: put_in(state.backend_state[__MODULE__], %{initialized: true})
    def ui(:provider_label, _state, opts), do: opts[:label]

    def ui({:message, :custom_message}, state, _opts),
      do: {:noreply, Map.put(state, :received, true)}

    def ui({:overlay, :model}, state, _opts), do: {:state, Map.put(state, :custom_overlay, true)}
    def ui(_event, _state, _opts), do: :pass
  end

  test "the configured list is complete and built-in identities are replaceable" do
    options = [tui_backends: [alto: {Interactive, label: "Host backend"}]]
    assert Backend.valid?(options[:tui_backends])
    assert Backend.items(options) == [%{label: "Host backend", value: :alto}]
    assert Backend.lookup(options, :codex) == {:error, {:backend_unavailable, :codex}}
  end

  test "custom interactive contributions use the same dispatch as built-ins" do
    state = %{
      run_options: [tui_backends: [host: {Interactive, label: "Host"}]],
      backend_state: %{OtherAdapter => :preserved},
      selected_backend: :host
    }

    initialized = Backend.initialize(state)
    assert initialized.backend_state[Interactive].initialized
    assert initialized.backend_state[OtherAdapter] == :preserved
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
    assert Backend.ui(state, :steering?)
    refute Backend.ui(%{state | selected_backend: :alto}, :steering?) == true
  end
end
