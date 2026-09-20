defmodule Alto.Runner.HistoryBoundariesTest do
  # The 257-boundary case deliberately exercises hundreds of durable writes.
  # Keep it out of the timing-sensitive concurrent participant tests.
  use ExUnit.Case, async: false

  defmodule Tick do
    @behaviour Alto.Tool
    def name(_opts), do: :tick
    def schema(_opts), do: %{parameters: %{type: "object", properties: %{}}}
    def execution_mode(_opts), do: :exclusive
    def approval(_opts), do: :never

    def run(_, _, opts) do
      send(opts[:owner], :tick)
      {:ok, "tick"}
    end
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto-history-boundaries-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    %{
      opts: [
        session: :new,
        session_dir: dir,
        session_history: :settled,
        tools: [{Tick, owner: self()}],
        run_timeout: 30_000
      ],
      dir: dir
    }
  end

  test "successive native effects advance settled boundaries beyond fence capacity", %{
    opts: opts,
    dir: dir
  } do
    opts = Keyword.put(opts, :loop, Alto.rule_loop(steps: List.duplicate("tick", 257)))
    assert {:ok, result} = Alto.run(%{}, opts)
    assert length(result.output) == 257
    assert result.persistence == :ok
    assert {:ok, snapshot} = Alto.Session.transcript(result.session_id, session_dir: dir)
    assert snapshot.revision > 256
  end

  test "a configured history cap fails before dispatch", %{opts: opts} do
    opts = Keyword.merge(opts, loop: Alto.rule_loop(steps: ["tick"]), max_conversation_bytes: 1)

    assert {:error, {:session_history_failed, {:conversation_storage_limit, %{max_bytes: 1}}}, _} =
             Alto.run(%{}, opts)

    refute_receive :tick
  end
end
