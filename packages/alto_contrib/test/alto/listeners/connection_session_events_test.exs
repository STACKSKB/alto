defmodule Alto.Contrib.Listeners.ConnectionSessionEventsTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Alto.Event
  alias Alto.Contrib.FrontEnd.Registry
  alias Alto.Contrib.Listeners.Connection
  alias Alto.Session

  test "fresh VM replays projection without creating atoms from stored terms", %{tmp_dir: dir} do
    key = "only_in_original_vm_#{System.unique_integer([:positive])}"
    data = %{String.to_atom(key) => "survives restart"}
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    :ok =
      Session.append(id, Session.event_record("run-1", Event.durable(:tool_completed, data)),
        session_dir: dir
      )

    command =
      JSON.encode!(%{"v" => 1, "id" => "replay", "type" => "session_events", "session_id" => id})

    script = """
    {:ok, page} = Alto.Session.events(#{inspect(id)}, session_dir: #{inspect(dir)})
    {:error, _} = Alto.Session.decode_term(hd(page.events)["data"])
    {:ok, registry} = Alto.Contrib.FrontEnd.Registry.start_link(name: nil,
      session_dir: #{inspect(dir)}, config_resolver: fn _ -> {:error, :unknown} end)
    Enum.each(Alto.Contrib.Listeners.Connection.command_lines(#{inspect(command)}, registry), &IO.write/1)
    """

    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script]

    {output, 0} =
      System.cmd(System.find_executable("elixir"), args,
        env: [{"ERL_FLAGS", "+S 2:2"}],
        stderr_to_stdout: true
      )

    reply =
      output
      |> String.split("\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, "{"))
      |> JSON.decode!()

    assert reply["type"] == "ok"
    assert hd(reply["events"])["data"] == %{key => "survives restart"}
  end

  test "oversized transcript replies fail explicitly instead of timing out", %{tmp_dir: dir} do
    {:ok, id} = Session.create("task", %{}, session_dir: dir)
    message = %{"role" => "user", "content" => String.duplicate("x", 4_000)}
    {:ok, _snapshot} = Session.persist_settled(id, [message], 4_000, session_dir: dir)

    pid =
      start_supervised!(
        {Registry, name: nil, session_dir: dir, config_resolver: fn _ -> {:error, :unknown} end}
      )

    line =
      JSON.encode!(%{
        "v" => 1,
        "type" => "session_transcript",
        "id" => "bounded",
        "session_id" => id
      })

    [output] = Connection.command_lines(line, pid, 512)
    reply = JSON.decode!(IO.iodata_to_binary(output))
    assert reply["type"] == "error"
    assert reply["id"] == "bounded"
    assert reply["detail"] == "reply_overflow"
  end
end
