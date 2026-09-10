defmodule Alto.Context do
  @moduledoc "Constructors for model-context policies."

  alias Alto.Context.Window

  @spec window(keyword()) :: Window.t()
  def window(opts \\ []), do: Window.new(opts)
end
