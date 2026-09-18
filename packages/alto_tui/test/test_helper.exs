ExUnit.start()

defmodule Alto.Test.Runner do
  def worker(%Alto.Runner.Handle{state: state}), do: worker(state)
  def worker(%Alto.Runner.TaskHost.Handle{pid: host}), do: :sys.get_state(host).task.pid
end

defmodule Alto.Test.TUI do
  def config(options \\ []) do
    options
    |> Keyword.put_new(:tui_backends,
      alto: {Alto.TUI.Backends.Native, label: "Alto native"},
      codex: {Alto.TUI.Backends.Codex, label: "Codex · ChatGPT"}
    )
    |> Alto.Config.new()
  end
end
