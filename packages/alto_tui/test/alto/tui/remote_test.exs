defmodule Alto.TUI.RemoteTest do
  use ExUnit.Case, async: false
  alias Alto.Contrib.Resident.{Config, Service, Tasks}
  alias Alto.TUI.{App, Backends.Remote, State}
  alias ExRatatui.Event.{Key, Paste}
  alias ExRatatui.Runtime

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_, _, options) do
      send(options[:owner], {:working, self()})

      receive do
        :finish -> {:ok, %{message: "Finished while detached", tool_calls: []}}
      end
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "alto-remote-#{Base.encode16(:crypto.strong_rand_bytes(6))}")

    File.mkdir_p!(root)

    config =
      Config.new(
        workspace: root,
        state_dir: Path.join(root, "state"),
        scheduling: [poll_ms: 10, workers: 1],
        profiles: %{
          "chat" =>
            Alto.Config.default(
              provider: {Provider, owner: self()},
              loop: Alto.chat_loop(),
              tools: [],
              run_timeout: 10_000
            )
        }
      )

    name = make_ref()
    start_supervised!({Service, config: config, name: name})
    on_exit(fn -> File.rm_rf!(root) end)

    options = [
      config: [
        provider: {Alto.Contrib.Providers.OpenAICompatible, model: "client-model"},
        models: [%{id: "client-model"}],
        tui_backends: [resident: {Remote, socket: Config.socket_path(config), profile: "chat"}]
      ],
      test_mode: {120, 36},
      name: nil,
      path: Path.join(root, "client.json"),
      credentials_path: Path.join(root, "credentials.json"),
      project: root
    ]

    %{options: options, config: config, name: name}
  end

  test "shared native terminal detaches without cancellation and reconnects to server history",
       ctx do
    {:ok, first} = App.start_link(ctx.options)
    ready(first)
    assert Runtime.snapshot(first).render_count > 0
    Runtime.inject_event(first, %Paste{content: "Inspect my repository"})
    Runtime.inject_event(first, %Key{code: "enter", kind: "press"})
    assert_receive {:working, provider}, 2_000
    eventually(fn -> state(first).selected_task_id != nil end)
    task_id = state(first).selected_task_id
    connection = state(first).backend_state[Remote].connection
    quit(first)
    eventually(fn -> not Process.alive?(connection) end)
    assert Process.alive?(provider)
    send(provider, :finish)

    {:ok, second} = App.start_link(ctx.options)
    ready(second)

    eventually(fn ->
      Enum.any?(List.flatten(Map.values(state(second).tasks)), &(&1["id"] == task_id))
    end)

    # Shared navigation invokes the remote selection hook; no local task catalog mutation.
    :sys.replace_state(second, fn runtime ->
      %{runtime | user_state: State.select_task(runtime.user_state, task_id)}
    end)

    eventually(fn ->
      Enum.any?(State.visible_entries(state(second)), &(&1.text == "Finished while detached"))
    end)

    assert ExRatatui.get_buffer_content(:sys.get_state(second).terminal_ref) =~
             "Finished while detached"

    eventually(fn ->
      {:ok, %{"task" => task}} = Tasks.command(ctx.name, "get", %{"id" => task_id})
      task["status"] == "completed"
    end)

    assert {:ok, local} = Alto.Contrib.Catalog.read(path: ctx.options[:path])
    assert local["tasks"] == []
    quit(second)
  end

  test "automatic reconnect after service restart retains delayed tasks", ctx do
    {:ok, terminal} = App.start_link(ctx.options)
    ready(terminal)

    assert {:ok, _} =
             Tasks.command(ctx.name, "submit", %{
               "id" => "later",
               "profile" => "chat",
               "task" => "later",
               "delay_ms" => 60_000
             })

    eventually(fn ->
      Enum.any?(List.flatten(Map.values(state(terminal).tasks)), &(&1["id"] == "later"))
    end)

    stop_supervised!(Service)
    eventually(fn -> state(terminal).backend_state[Remote].model.connection == "disconnected" end)
    start_supervised!({Service, config: ctx.config, name: ctx.name})
    ready(terminal)

    assert Enum.any?(
             List.flatten(Map.values(state(terminal).tasks)),
             &(&1["id"] == "later" and &1["status"] == "queued")
           )

    quit(terminal)
  end

  test "shared folder form completes and creates paths on the service host", ctx do
    root = ctx.config.workspace
    File.mkdir_p!(Path.join(root, "Folder Alpha"))
    {:ok, terminal} = App.start_link(ctx.options)
    ready(terminal)

    :sys.replace_state(terminal, fn runtime ->
      %{runtime | user_state: Remote.ui(:workspace_form, runtime.user_state, [])}
    end)

    eventually(fn -> state(terminal).overlay.completion_pending? == false end)
    assert (root <> "/") in state(terminal).overlay.suggestions

    Runtime.inject_event(terminal, %Paste{content: Path.join(root, "Folder A")})
    Runtime.inject_event(terminal, %Key{code: "tab", kind: "press"})

    eventually(fn ->
      Alto.TUI.Menu.value(state(terminal).overlay, :path) ==
        Path.join(root, "Folder Alpha") <> "/"
    end)

    Runtime.inject_event(terminal, %Key{code: "enter", kind: "press"})

    eventually(fn ->
      model = state(terminal).backend_state[Remote].model
      model.workspace_root == Path.join(root, "Folder Alpha")
    end)

    :sys.replace_state(terminal, fn runtime ->
      %{runtime | user_state: Remote.ui(:workspace_form, runtime.user_state, [])}
    end)

    Runtime.inject_event(terminal, %Paste{content: "Created on service"})
    Runtime.inject_event(terminal, %Key{code: "n", modifiers: ["ctrl"], kind: "press"})
    eventually(fn -> File.dir?(Path.join(root, "Created on service")) end)
    eventually(fn -> state(terminal).overlay == nil end)
    quit(terminal)
  end

  test "leaving remote navigation restores the local catalog and keeps provider choices", ctx do
    {:ok, terminal} = App.start_link(ctx.options)
    ready(terminal)
    current = state(terminal)
    local_root = ctx.config.workspace
    {:ok, project} = Alto.Contrib.Catalog.register_project(local_root, path: ctx.options[:path])

    {:ok, local_task} =
      Alto.Contrib.Catalog.create_task(project["id"], "Local draft", path: ctx.options[:path])

    next = Remote.ui(:leaving, current, [])
    assert Enum.any?(next.tasks[project["id"]], &(&1["id"] == local_task["id"]))
    assert next.selected_task_id == nil
    assert next.profiles == current.profiles
    assert next.profiles != []
    quit(terminal)
  end

  test "delayed submission replies preserve edited drafts and drafts after switching backend",
       ctx do
    options =
      Keyword.update!(ctx.options, :config, fn config ->
        Keyword.update!(config, :tui_backends, fn backends ->
          backends ++ [local: {Alto.TUI.Backends.Native, []}]
        end)
      end)

    for switch? <- [false, true] do
      {:ok, terminal} = App.start_link(options)
      ready(terminal)
      connection = state(terminal).backend_state[Remote].connection
      :sys.suspend(connection)
      on_exit(fn -> if Process.alive?(connection), do: :sys.resume(connection) end)

      Runtime.inject_event(terminal, %Paste{content: "Submitted draft"})
      Runtime.inject_event(terminal, %Key{code: "enter", kind: "press"})
      eventually(fn -> state(terminal).backend_state[Remote].busy end)

      if switch? do
        Runtime.inject_event(terminal, %Key{code: "f5", kind: "press"})
        eventually(fn -> state(terminal).overlay != nil end)
        Runtime.inject_event(terminal, %Key{code: "down", kind: "press"})
        Runtime.inject_event(terminal, %Key{code: "enter", kind: "press"})
        eventually(fn -> state(terminal).selected_backend == :local end)
      end

      ExRatatui.textarea_set_value(state(terminal).textarea, "New draft")
      :sys.resume(connection)
      assert_receive {:working, provider}, 2_000
      eventually(fn -> not state(terminal).backend_state[Remote].busy end)
      assert ExRatatui.textarea_get_value(state(terminal).textarea) == "New draft"
      send(provider, :finish)

      eventually(fn ->
        id = state(terminal).backend_state[Remote].model.selected_id
        {:ok, %{"task" => task}} = Tasks.command(ctx.name, "get", %{"id" => id})
        task["status"] == "completed"
      end)

      quit(terminal)
    end
  end

  defp state(pid), do: :sys.get_state(pid).user_state

  defp ready(pid),
    do:
      eventually(fn ->
        model = state(pid).backend_state[Remote].model
        model && model.connection == "connected"
      end)

  defp quit(pid) do
    ref = Process.monitor(pid)
    Runtime.inject_event(pid, %Key{code: "c", modifiers: ["ctrl"], kind: "press"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  defp eventually(fun, attempts \\ 250)
  defp eventually(_fun, 0), do: flunk("remote terminal did not reach expected state")

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          eventually(fun, attempts - 1)
        )
  end
end
