defmodule Alto.TUI.TestSupport do
  @moduledoc false

  def eventually(fun, attempts \\ 250)
  def eventually(_fun, 0), do: ExUnit.Assertions.flunk("TUI did not reach expected state")

  def eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
