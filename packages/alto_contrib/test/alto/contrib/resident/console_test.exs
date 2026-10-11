defmodule Alto.Contrib.Resident.ConsoleTest do
  use ExUnit.Case, async: false
  alias Alto.Contrib.Socket.Client
  alias Alto.Contrib.Resident.{Config, Console, Service, Tasks}

  test "console display presents returned maps and protocol tuples as readable fields" do
    value = %{
      "$tuple" => [
        "http_error",
        429,
        %{"error" => %{"message" => "Rate limit exceeded", "retry_after" => 30}}
      ]
    }

    text = Console.clean(value)
    assert text =~ "Provider returned HTTP 429"
    assert text =~ "Rate limit exceeded"
    assert text =~ "Retry after: 30"
    refute text =~ "%{"
    refute text =~ "$tuple"
    refute text =~ "=>"
    assert Console.clean(%{exit_code: 1, stderr: "No such file"}) =~ "Stderr: No such file"
    assert Console.clean("example: %{key: :value}") == "example: %{key: :value}"
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}
    def list_models(_), do: {:ok, [%{id: "test-model", efforts: ["low", "high"]}]}

    def stream(request, sink, opts) do
      send(Keyword.fetch!(opts, :owner), {:executing, self(), request.messages})

      send(Keyword.fetch!(opts, :owner), {:selected_effort, opts[:reasoning_effort]})
      await(sink, "")
    end

    defp await(sink, reasoning) do
      receive do
        {:reasoning, text} ->
          sink.(Alto.Event.live(:model_reasoning_delta, %{text: text}))
          await(sink, reasoning <> text)

        {:finish, text} ->
          {:ok,
           %{
             message: text,
             tool_calls: [],
             reasoning: reasoning,
             provider_fields: %{"reasoning" => reasoning},
             usage: %{input_tokens: 10, output_tokens: 5}
           }}
      end
    end
  end

  defmodule GuardedTool do
    @behaviour Alto.Tool
    def name(_opts), do: :echo
    def schema(_opts), do: %{description: "Echo", parameters: %{type: "object", properties: %{}}}
    def execution_mode(_opts), do: :parallel
    def approval(_opts), do: :required
    def run(args, _, _opts), do: {:ok, args}
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "zek-console-#{Base.encode16(:crypto.strong_rand_bytes(6))}")

    File.mkdir_p!(dir)

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        profiles: %{
          "chat" =>
            Alto.Config.default(
              provider: {Provider, owner: self(), model: "test-model"},
              loop: Alto.chat_loop(),
              tools: [],
              run_timeout: 10_000
            ),
          "guarded" =>
            Alto.Config.default(
              provider: nil,
              loop: Alto.rule_loop(steps: ["echo"]),
              tools: [GuardedTool],
              approval: &Alto.Contrib.Approval.socket/2,
              approval_timeout: 10_000
            )
        }
      )

    name = make_ref()
    start_supervised!({Service, config: config, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{config: config, name: name, opts: [socket: Config.socket_path(config), profile: "chat"]}
  end

  test "effort is validated and reaches execution; reasoning streams and survives reconnect", %{
    opts: opts,
    name: name
  } do
    model = Console.perform(Console.new(opts), :connect, self())
    model = Console.perform(model, :efforts, self())
    assert model.effort_catalog["efforts"] == ["low", "high"]

    assert {:error, :unsupported_reasoning_effort} =
             Tasks.command(name, "submit", %{
               "profile" => "chat",
               "task" => "reject",
               "reasoning_effort" => "invalid"
             })

    model = Console.perform(model, {:effort, "high"}, self())
    model = Console.perform(model, {:submit, "think"}, self())
    assert model.notice == "Sent"
    assert_receive {:executing, provider, _}, 2000
    assert_receive {:selected_effort, "high"}
    send(provider, {:reasoning, "Checking the files"})

    model =
      eventually(model, fn m ->
        Enum.any?(m.entries, &(&1.kind == :reasoning and &1.text == "Checking the files"))
      end)

    assert Enum.any?(model.live, fn {_, phase} -> phase == "model_reasoning_delta" end)
    send(provider, {:finish, "Done"})
    model = eventually(model, fn m -> Enum.any?(m.tasks, &(&1.status == "completed")) end)

    model =
      Console.perform(model, :efforts, self())
      |> Console.perform({:effort, "low"}, self())
      |> Console.perform({:submit, "continue"}, self())

    assert_receive {:executing, next_provider, history}, 2000
    assert_receive {:selected_effort, "low"}
    assert Enum.any?(history, &(Alto.Contrib.Reasoning.text(&1) == "Checking the files"))
    send(next_provider, {:finish, "Next answer"})

    model =
      eventually(model, fn m ->
        Enum.any?(m.tasks, &(&1.id == m.selected_id and &1.status == "completed"))
      end)

    id = model.selected_id
    Console.close(model)

    model =
      Console.perform(Console.new(opts), :connect, self())
      |> Console.perform({:select, id}, self())

    assert Enum.any?(model.entries, &(&1.kind == :reasoning and &1.text == "Checking the files"))
    assert Enum.any?(model.entries, &(&1.text == "Done"))
    Console.close(model)
  end

  test "two clients recover the same conversation, follow up, and replay after restart", %{
    opts: opts,
    config: config,
    name: name
  } do
    first = Console.perform(Console.new(opts), :connect, self())
    assert first.connection == "connected"
    first = Console.perform(first, {:submit, "first prompt"}, self())
    assert first.notice == "Sent"
    assert_receive {:executing, provider, _}, 2_000
    session = first.selected_id
    Console.close(first)
    assert Process.alive?(provider)
    send(provider, {:finish, "first answer"})

    second = Console.perform(Console.new(opts), :connect, self())
    second = Console.perform(second, {:select, session}, self())

    second =
      eventually(second, fn m ->
        Enum.any?(m.entries, &(&1.text == "first answer")) and hd(m.tasks).status == "completed"
      end)

    assert Enum.any?(second.entries, &(&1.text == "first prompt"))
    assert hd(second.tasks).usage["total_tokens"] == 15

    first = Console.perform(first, :connect, self())
    assert first.entries == second.entries
    second = Console.perform(second, {:submit, "follow up"}, self())
    assert second.notice == "Sent"
    assert_receive {:executing, provider, messages}, 2_000
    assert Enum.any?(messages, &(&1["content"] == "first answer"))
    send(provider, {:finish, "second answer"})

    second =
      eventually(second, fn m ->
        Enum.any?(m.entries, &(&1.text == "second answer")) and hd(m.tasks).status == "completed"
      end)

    first = eventually(first, fn m -> m.entries == second.entries end)
    Console.close(first)
    Console.close(second)

    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    recovered = Console.perform(second, :connect, self())
    assert recovered.entries == second.entries
    assert hd(recovered.tasks).run_id == hd(second.tasks).run_id
    assert hd(recovered.tasks).durable
    assert recovered.connection == "connected"
    Console.close(recovered)
  end

  test "approval reconnect and decisions are scoped to the selected task", %{opts: opts} do
    model = Console.perform(Console.new(Keyword.put(opts, :profile, "guarded")), :connect, self())
    model = Console.perform(model, {:submit, "{}"}, self())
    model = eventually(model, fn m -> map_size(m.approvals) == 1 end)
    session = model.selected_id
    Console.close(model)
    model = Console.perform(model, :connect, self())
    assert model.detail =~ "Decision: echo"
    model = Console.perform(model, :new, self())
    untouched = Console.perform(model, :approve, self())
    assert map_size(untouched.approvals) == 1
    model = Console.perform(model, {:select, session}, self())
    model = Console.perform(model, :approve, self())
    model = eventually(model, fn m -> hd(m.tasks).status == "completed" end)
    assert map_size(model.approvals) == 0
    Console.close(model)
  end

  test "a background connector transfers lifetime to the UI owner", %{opts: opts} do
    owner = self()

    model =
      Task.async(fn -> Console.perform(Console.new(opts), :connect, owner) end) |> Task.await()

    assert Process.alive?(model.client.pid)
    assert {:ok, _} = Client.request(model.client, %{type: "runs"})
    model = Console.perform(model, {:submit, "cancel me"}, self())
    assert_receive {:executing, _provider, _}, 2_000
    model = Console.perform(model, :cancel, self())
    model = eventually(model, fn m -> hd(m.tasks).status == "cancelled" end)
    Console.close(model)
    disconnected = Console.perform(model, :poll, self())
    assert disconnected.connection == "disconnected"
    assert disconnected.client == nil
  end

  test "delayed tasks are selectable and cancellable before any session exists", %{
    opts: opts,
    name: name
  } do
    Tasks.command(name, "submit", %{
      "id" => "delayed",
      "profile" => "chat",
      "task" => "scheduled message",
      "delay_ms" => 60_000
    })

    model = Console.perform(Console.new(opts), :connect, self())
    model = Console.perform(model, {:select, "delayed"}, self())
    assert model.connection == "connected"
    assert model.detail =~ "queued"
    assert model.history == []
    assert Enum.any?(model.entries, &(&1.text == "scheduled message"))
    blocked = Console.perform(model, {:submit, "cannot follow yet"}, self())
    assert blocked.notice =~ "still running"
    model = Console.perform(model, :cancel, self())
    assert model.detail =~ "cancelled"
    refute_receive {:executing, _, _}, 100
    Console.close(model)
  end

  test "restart exposes uncertain work and fences decisions made from stale views", %{
    opts: opts,
    name: name,
    config: config
  } do
    model = Console.perform(Console.new(opts), :connect, self())
    model = Console.perform(model, {:submit, "uncertain"}, self())
    assert_receive {:executing, _, _}, 2_000
    id = model.selected_id

    model =
      eventually(model, fn m -> Enum.any?(m.tasks, &(&1.id == id && &1.status == "running")) end)

    Console.close(model)
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    model = Console.perform(model, :connect, self())
    assert model.detail =~ "requires_operator"
    assert model.detail =~ "/retry NOTE"
    assert model.notice == "Connected"

    stale =
      Console.perform(Console.new(opts), :connect, self())
      |> Console.perform({:select, id}, self())

    blocked = Console.perform(model, {:submit, "blind followup"}, self())
    assert blocked.notice =~ "Resolve the uncertain outcome"

    model =
      Console.perform(model, {:reconcile, "retry", "controlled provider had no effects"}, self())

    assert model.notice == "Decision recorded"
    stale = Console.perform(stale, {:reconcile, "retry", "stale second decision"}, self())
    assert stale.notice =~ "Request rejected"
    assert_receive {:executing, provider, _}, 2_000
    send(provider, {:finish, "recovered"})

    model =
      eventually(model, fn m -> Enum.any?(m.tasks, &(&1.id == id && &1.status == "completed")) end)

    refute_receive {:executing, _, _}, 100
    Console.close(model)
    Console.close(stale)
  end

  defp eventually(model, predicate, attempts \\ 100)
  defp eventually(model, _predicate, 0), do: flunk("state did not settle: #{inspect(model)}")

  defp eventually(model, predicate, attempts) do
    if predicate.(model) do
      model
    else
      Process.sleep(20)
      eventually(Console.perform(model, :poll, self()), predicate, attempts - 1)
    end
  end
end
