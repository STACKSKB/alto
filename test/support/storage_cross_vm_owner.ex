defmodule Alto.StorageCrossVMOwner do
  @moduledoc false

  def hold_queue(opts) do
    {:ok, _pid} = Alto.Queue.start_link(opts)
    Process.sleep(:infinity)
  end
end
