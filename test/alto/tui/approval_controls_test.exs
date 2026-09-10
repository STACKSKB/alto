defmodule Alto.TUI.ApprovalControlsTest do
  use ExUnit.Case, async: false

  alias Alto.TUI.{App, State, View}
  alias ExRatatui.Event.Mouse

  defmodule Provider do
    @behaviour Alto.Provider

    def describe(opts), do: %{model: opts[:model], context_window: 100_000}
    def list_models(_opts), do: {:ok, []}
    def stream(_request, _sink, _opts), do: {:error, :not_used}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "alto-approval-controls-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    config =
      Alto.Config.new(
        provider_profiles: [
          [id: "test", label: "Test", provider: {Provider, model: "test/model"}]
        ],
        loop: Alto.chat_loop(),
        tools: [],
        tui: [approval_auto_open: true]
      )

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, catalog: Path.join(root, "catalog.json"), config: config}
  end

  test "renders labeled desktop controls and accepts clicks on their labels", context do
    state = pending_state(context, {140, 40})
    {buffer, _terminal} = render(state, 140, 40)
    assert {:ok, approve} = label_position(buffer, "[ Approve F8 ]")
    assert {:ok, deny} = label_position(buffer, "[ Deny F9 ]")
    assert approve.y < deny.y

    approve_event = click_at(approve, "[ Approve F8 ]")

    assert View.hit_target(state, 140, 40, approve_event.x, approve_event.y) ==
             {:approval, :approve}

    assert {:noreply, decided} = App.handle_event(approve_event, state)
    assert_receive {:alto_approval_decision, "approval-1", :approve}
    assert decided.pending_approvals == []

    state = pending_state(context, {140, 40})
    {buffer, _terminal} = render(state, 140, 40)
    {:ok, deny} = label_position(buffer, "[ Deny F9 ]")

    assert {:noreply, decided} = App.handle_event(click_at(deny, "[ Deny F9 ]"), state)
    assert_receive {:alto_approval_decision, "approval-1", {:deny, :user_denied}}
    assert decided.pending_approvals == []
  end

  test "blank space and the details bottom border never decide an approval", context do
    state = pending_state(context, {140, 40})
    layout = View.layout(state, 140, 40)
    {buffer, _terminal} = render(state, 140, 40)
    {:ok, approve} = label_position(buffer, "[ Approve F8 ]")

    blank_x = approve.x + String.length("[ Approve F8 ]") + 1

    assert {:noreply, unchanged} =
             App.handle_event(
               %Mouse{kind: "down", button: "left", x: blank_x, y: approve.y},
               state
             )

    assert unchanged.pending_approvals == state.pending_approvals
    refute_receive {:alto_approval_decision, "approval-1", _decision}, 100

    assert {:noreply, unchanged} =
             App.handle_event(
               %Mouse{
                 kind: "down",
                 button: "left",
                 x: blank_x,
                 y: layout.details.y + layout.details.height - 1
               },
               state
             )

    assert unchanged.pending_approvals == state.pending_approvals
    refute_receive {:alto_approval_decision, "approval-1", _decision}, 100
  end

  test "keeps drawer controls pinned while details scrolls and accepts a narrow click", context do
    state = pending_state(context, {80, 24})
    assert state.details_drawer_open?
    scrolled = %{state | details_scroll: 100}
    {buffer, _terminal} = render(scrolled, 80, 24)

    assert {:ok, approve} = label_position(buffer, "[ Approve F8 ]")
    assert {:ok, deny} = label_position(buffer, "[ Deny F9 ]")
    assert approve.y < deny.y

    assert {:noreply, decided} = App.handle_event(click_at(deny, "[ Deny F9 ]"), scrolled)
    assert_receive {:alto_approval_decision, "approval-1", {:deny, :user_denied}}
    assert decided.pending_approvals == []
  end

  defp pending_state(context, dimensions) do
    assert {:ok, state} =
             State.new(context.config,
               project: context.root,
               path: context.catalog,
               credentials_path: Path.join(context.root, "credentials.json")
             )

    state = %{state | dimensions: dimensions, focus: :composer}
    request = %{id: "approval-1", tool: "record_mutation", arguments: %{}, details: %{}}

    assert {:noreply, prompted} =
             App.handle_info({:alto_approval_request, "run-1", request, self()}, state)

    prompted
  end

  defp render(state, width, height) do
    terminal = ExRatatui.init_test_terminal(width, height)
    assert :ok = ExRatatui.draw(terminal, View.widgets(state, %{width: width, height: height}))
    {ExRatatui.get_buffer_content(terminal), terminal}
  end

  defp label_position(buffer, label) do
    buffer
    |> String.split("\n", trim: false)
    |> Enum.with_index()
    |> Enum.find_value(:error, fn {line, y} ->
      case :binary.match(line, label) do
        {byte_x, _length} ->
          {:ok, %{x: String.length(binary_part(line, 0, byte_x)), y: y}}

        :nomatch ->
          false
      end
    end)
  end

  defp click_at(%{x: x, y: y}, label),
    do: %Mouse{kind: "down", button: "left", x: x + div(String.length(label), 2), y: y}
end
