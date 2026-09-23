defmodule Alto.TUI.RunLifecycleTest do
  use ExUnit.Case, async: false

  alias Alto.TUI.{App, State, View}
  alias ExRatatui.Event.Key
  alias ExRatatui.Runtime

  defmodule ControlledProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, sink, opts) do
      send(opts[:owner], {:model_waiting, self(), request.messages})
      respond(sink, "")
    end

    defp respond(sink, received) do
      receive do
        {:delta, text} ->
          sink.(Alto.Event.live(:model_delta, %{text: text}))
          respond(sink, received <> text)

        {:finish, text} ->
          sink.(Alto.Event.live(:model_delta, %{text: text}))
          {:ok, %{message: received <> text, tool_calls: []}}

        :fail ->
          {:error, :controlled_failure}
      end
    end
  end

  defmodule ApprovalProbe do
    @behaviour Alto.Tool
    def name(_opts), do: :approval_probe
    def schema(_opts), do: %{parameters: %{type: "object", properties: %{}}}
    def execution_mode(_opts), do: :exclusive
    def approval(_opts), do: :required
    def run(args, _context, _opts), do: {:ok, args}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "alto-tui-lifecycle-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "queued input preserves distinct streamed turns", %{root: root} do
    app = start_app(root)
    submit(app, "first")
    assert_receive {:model_waiting, first, _}, 5_000
    send(first, {:delta, "first "})
    eventually(fn -> List.last(State.current_entries(state(app)))[:text] == "first " end)

    submit(app, "next")
    assert screen(app) =~ "Queued message: next"

    assert State.current_entries(state(app)) == [
             %{kind: :user, text: "first"},
             %{kind: :assistant, text: "first "}
           ]

    send(first, {:finish, "done"})
    assert_receive {:model_waiting, second, _}, 5_000

    assert State.current_entries(state(app)) == [
             %{kind: :user, text: "first"},
             %{kind: :assistant, text: "first done"},
             %{kind: :user, text: "next"}
           ]

    refute screen(app) =~ "Queued message:"
    refute state(app).notice =~ "message queued"

    send(second, {:finish, "second done"})
    eventually(fn -> state(app).runs == %{} end)

    expected = [
      %{kind: :user, text: "first"},
      %{kind: :assistant, text: "first done"},
      %{kind: :user, text: "next"},
      %{kind: :assistant, text: "second done"}
    ]

    assert State.current_entries(state(app)) == expected
    rendered = screen(app)
    assert rendered =~ "you › next"
    assert length(Regex.scan(~r/alto ›/, rendered)) == 2
    refute rendered =~ "Queued message:"
    assert state(app).input_routes == %{}

    session_id = State.selected_task(state(app))["conversation_id"]

    assert {:ok, %{messages: messages}} =
             Alto.Session.transcript(session_id, session_dir: Path.join(root, "sessions"))

    assert Alto.ToolDisplay.transcript(messages) == expected
  end

  test "a queued follow-up starts after completion without changing the foreground draft", %{
    root: root
  } do
    app = start_app(root)
    submit(app, "first")
    assert_receive {:model_waiting, first, _}, 5_000
    assert State.run_label(state(app)) =~ "waiting for model"
    original_task = state(app).selected_task_id

    submit(app, "next")
    assert [%{text: "next"}] = Alto.Input.list(state(app).inputs[original_task])
    assert map_size(state(app).runs) == 1
    refute_receive {:model_waiting, _, _}, 50

    key(app, "g", ["ctrl"])
    key(app, "n")
    ExRatatui.textarea_set_value(state(app).textarea, "another task's draft")
    assert state(app).selected_task_id == nil
    send(first, {:finish, "first done"})

    assert_receive {:model_waiting, second, messages}, 5_000
    assert List.last(messages) == %{"role" => "user", "content" => "next"}
    assert Enum.any?(messages, &(&1["content"] == "first done"))
    assert state(app).selected_task_id == nil
    assert ExRatatui.textarea_get_value(state(app).textarea) == "another task's draft"
    assert state(app).input_routes == %{}

    assert state(app).entries[original_task] == [
             %{kind: :user, text: "first"},
             %{kind: :assistant, text: "first done"},
             %{kind: :user, text: "next"}
           ]

    assert Enum.all?(state(app).runs, fn {_, run} -> run.task_id == original_task end)
    send(second, {:finish, "second done"})
    eventually(fn -> state(app).runs == %{} end)
  end

  test "Esc cancels a waiting provider, preserves drafts, and pauses queued work until Enter", %{
    root: root
  } do
    app = start_app(root)
    submit(app, "first")
    assert_receive {:model_waiting, first, _}, 5_000
    task_id = state(app).selected_task_id
    submit(app, "next")
    ExRatatui.textarea_set_value(state(app).textarea, "draft kept")
    monitor = Process.monitor(first)
    key(app, "esc")
    assert_receive {:DOWN, ^monitor, :process, ^first, _}, 5_000
    eventually(fn -> state(app).runs == %{} end)
    assert ExRatatui.textarea_get_value(state(app).textarea) == "draft kept"
    assert length(Alto.Input.list(state(app).inputs[task_id])) == 1
    refute_receive {:model_waiting, _, _}, 50
    assert state(app).notice =~ "queued message paused"

    ExRatatui.textarea_set_value(state(app).textarea, "")
    key(app, "enter")
    assert_receive {:model_waiting, second, messages}, 5_000
    assert List.last(messages)["content"] == "next"

    assert Enum.count(State.current_entries(state(app)), &(&1 == %{kind: :user, text: "next"})) ==
             1

    refute screen(app) =~ "Queued message:"
    send(second, {:finish, "done"})
    eventually(fn -> state(app).runs == %{} end)
  end

  test "provider failure releases the task and leaves a queued message available", %{root: root} do
    app = start_app(root)
    submit(app, "first")
    assert_receive {:model_waiting, first, _}, 5_000
    submit(app, "next")
    send(first, :fail)
    eventually(fn -> state(app).runs == %{} end)
    assert State.selected_task(state(app))["status"] == "failed"
    assert State.run_label(state(app)) =~ "Enter send"
    key(app, "enter")
    assert_receive {:model_waiting, second, _}, 5_000
    send(second, {:finish, "done"})
    eventually(fn -> state(app).runs == %{} end)
  end

  test "a second queued message stays in the draft without replacing the first", %{root: root} do
    app = start_app(root)
    submit(app, "first")
    assert_receive {:model_waiting, first, _}, 5_000
    submit(app, "next")
    submit(app, "later")
    task_id = state(app).selected_task_id
    assert [%{text: "next"}] = Alto.Input.list(state(app).inputs[task_id])
    assert ExRatatui.textarea_get_value(state(app).textarea) == "later"
    assert state(app).notice =~ "one message already queued"
    send(first, {:finish, "done"})
    assert_receive {:model_waiting, second, messages}, 5_000
    assert List.last(messages)["content"] == "next"
    assert ExRatatui.textarea_get_value(state(app).textarea) == "later"
    send(second, {:finish, "done"})
    eventually(fn -> state(app).runs == %{} end)
  end

  test "ctrl-enter sends steering input through the native channel", %{root: root} do
    app = start_app(root)
    submit(app, "first")
    assert_receive {:model_waiting, first, _}, 5_000

    ExRatatui.textarea_set_value(state(app).textarea, "change direction")
    key(app, "enter", ["ctrl"])

    task_id = state(app).selected_task_id
    input = state(app).inputs[task_id]
    assert [%{mode: :steer, text: "change direction"}] = Alto.Input.list(input)
    send(first, {:finish, "first done"})

    assert_receive {:model_waiting, second, messages}, 5_000
    assert List.last(messages) == %{"role" => "user", "content" => "change direction"}
    eventually(fn -> state(app).input_routes == %{} end)

    assert List.last(State.current_entries(state(app))) == %{
             kind: :user,
             text: "change direction"
           }

    refute screen(app) =~ "Steering message:"
    send(second, {:finish, "second done"})
    eventually(fn -> state(app).runs == %{} end)
  end

  test "draining one retained input keeps the route for later entries", %{root: root} do
    app = start_app(root)
    submit(app, "first")
    assert_receive {:model_waiting, _first, _}, 5_000
    task_id = state(app).selected_task_id

    ExRatatui.textarea_set_value(state(app).textarea, "steer next")
    key(app, "enter", ["ctrl"])
    submit(app, "follow later")
    assert length(Alto.Input.list(state(app).inputs[task_id])) == 2

    key(app, "esc")
    eventually(fn -> state(app).runs == %{} end)
    key(app, "g", ["ctrl"])
    key(app, "n")
    assert state(app).selected_task_id == nil

    send(app, {:alto_tui_send_input, task_id})
    assert_receive {:model_waiting, second, messages}, 5_000
    assert List.last(messages)["content"] == "steer next"
    assert state(app).selected_task_id == nil
    assert Map.has_key?(state(app).input_routes, task_id)
    assert [%{text: "follow later"}] = Alto.Input.list(state(app).inputs[task_id])

    send(second, {:finish, "done"})
    assert_receive {:model_waiting, third, messages}, 5_000
    assert List.last(messages)["content"] == "follow later"
    send(third, {:finish, "done"})
    eventually(fn -> state(app).runs == %{} end)
  end

  test "an unexpected runner exit releases the task without forgetting its saved session", %{
    root: root
  } do
    app = start_app(root)
    submit(app, "first")
    assert_receive {:model_waiting, first, _}, 5_000
    send(first, {:finish, "saved response"})
    eventually(fn -> state(app).runs == %{} end)
    session_id = State.selected_task(state(app))["conversation_id"]
    assert is_binary(session_id)

    submit(app, "second")
    assert_receive {:model_waiting, provider, _}, 5_000
    on_exit(fn -> if Process.alive?(provider), do: Process.exit(provider, :kill) end)
    submit(app, "next")
    [run] = Map.values(state(app).runs)
    Process.exit(Alto.Test.Runner.worker(run.handle), :kill)
    eventually(fn -> state(app).runs == %{} end)
    assert State.selected_task(state(app))["status"] == "failed"
    assert State.selected_task(state(app))["conversation_id"] == session_id
    assert state(app).notice =~ "queued message paused"
    assert Process.alive?(app)
  end

  test "queuing does not hide approvals and cancellation removes their stale handles", %{
    root: root
  } do
    app =
      start_app(root,
        provider: nil,
        loop: Alto.rule_loop(steps: ["approval_probe"]),
        tools: [ApprovalProbe],
        approval: Alto.Approvals.Interactive
      )

    submit(app, "{}")
    eventually(fn -> state(app).pending_approvals != [] end)
    [{local_id, _}] = Map.to_list(state(app).runs)
    assert hd(state(app).pending_approvals).local_id == local_id
    assert State.run_label(state(app)) =~ "waiting for approval"

    # The approval can focus the details pane; click/Tab back to the composer.
    :sys.replace_state(app, fn runtime ->
      %{runtime | user_state: %{runtime.user_state | focus: :composer}}
    end)

    submit(app, "next")
    terminal = ExRatatui.init_test_terminal(160, 40)
    ExRatatui.draw(terminal, View.widgets(state(app), %{width: 160, height: 40}))
    screen = ExRatatui.get_buffer_content(terminal)
    assert screen =~ "approval required"
    assert screen =~ "waiting for approval"
    assert screen =~ "1 queued"
    key(app, "esc")
    eventually(fn -> state(app).runs == %{} end)
    assert state(app).pending_approvals == []
    key(app, "f8")
    assert state(app).notice == "no pending approval"
  end

  test "timed-out approvals disappear without requiring a reply to a dead waiter", %{root: root} do
    app =
      start_app(root,
        provider: nil,
        loop: Alto.rule_loop(steps: ["approval_probe"]),
        tools: [ApprovalProbe],
        approval: Alto.Approvals.Interactive,
        approval_timeout: 500
      )

    submit(app, "{}")
    eventually(fn -> state(app).pending_approvals != [] end)
    eventually(fn -> state(app).runs == %{} end)
    assert state(app).pending_approvals == []
  end

  defp start_app(root, options \\ nil, backend \\ Alto.TUI.Backends.Native) do
    options =
      options ||
        [
          provider_profiles: [
            [
              id: "controlled",
              label: "Controlled",
              provider: {ControlledProvider, owner: self(), model: "test"},
              models: [%{id: "test"}]
            ]
          ],
          loop: Alto.chat_loop(),
          tools: []
        ]

    config =
      options
      |> Keyword.put(:tui_backends, alto: {backend, []})
      |> Keyword.put(:session_dir, Path.join(root, "sessions"))
      |> Alto.Test.TUI.config()

    {:ok, app} =
      App.start_link(
        config: config,
        project: root,
        path: Path.join(root, "catalog.json"),
        credentials_path: Path.join(root, "credentials.json"),
        test_mode: {160, 40},
        name: nil
      )

    Process.unlink(app)
    on_exit(fn -> if Process.alive?(app), do: GenServer.stop(app) end)
    app
  end

  defp state(app), do: :sys.get_state(app).user_state

  defp screen(app) do
    terminal = ExRatatui.init_test_terminal(160, 40)
    :ok = ExRatatui.draw(terminal, App.render(state(app), %{width: 160, height: 40}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp key(app, code, modifiers \\ []),
    do: Runtime.inject_event(app, %Key{code: code, kind: "press", modifiers: modifiers})

  defp submit(app, message) do
    ExRatatui.textarea_set_value(state(app).textarea, message)
    key(app, "enter")
  end

  defp eventually(fun, remaining \\ 250)

  defp eventually(fun, remaining) when remaining > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          eventually(fun, remaining - 1)
        )
  end

  defp eventually(_, 0), do: flunk("TUI did not reach expected state")
end
