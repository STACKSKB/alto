defmodule Alto.FrontEnd.RegistryWorkspacesTest do
  use ExUnit.Case, async: true
  alias Alto.FrontEnd.Registry

  defmodule FolderTool do
    use Alto.Tool, name: :folder, execution_mode: :parallel, approval: :never

    def schema(_opts),
      do: %{description: "Report folder", parameters: %{type: "object", properties: %{}}}

    def run(_, context, opts) do
      send(opts[:owner], {:folder, context.cwd})
      {:ok, context.cwd}
    end
  end

  test "trusted per-run folder overrides do not change the next run's default" do
    root = Path.join(System.tmp_dir!(), "alto-folders-#{System.unique_integer([:positive])}")
    other = Path.join(root, "other")
    File.mkdir_p!(other)
    on_exit(fn -> File.rm_rf!(root) end)

    options = [
      provider: nil,
      loop: Alto.rule_loop(steps: ["folder"]),
      tools: [{FolderTool, owner: self()}]
    ]

    registry =
      start_supervised!(
        {Registry, name: nil, cwd: root, config_resolver: fn "test" -> {:ok, options} end}
      )

    assert {:ok, run} = Registry.start_run(registry, "test", "{}", cwd: other)
    assert_folder(registry, run, other)
    assert {:ok, run} = Registry.start_run(registry, "test", "{}")
    assert_folder(registry, run, root)
  end

  defp assert_folder(registry, run, expected) do
    receive do
      {:folder, ^expected} -> :ok
    after
      5_000 -> flunk("Folder tool did not run: #{inspect(Registry.run_result(registry, run))}")
    end
  end
end
