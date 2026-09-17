defmodule Alto.FrontEnd.Gui do
  @moduledoc """
  The built-in single-page GUI served by `Alto.Listeners.WebServer`.

  One static page, no build step and no external assets: it speaks the same
  front-end protocol over a same-origin WebSocket (`GET /ws`), attaching to
  all runs, streaming model deltas and tool activity, answering approval
  requests, and starting or cancelling runs from the browser. The server's
  origin check and configured upgrade authentication protect the connection.
  """

  @external_resource Path.expand("../../../priv/gui/index.html", __DIR__)
  @html File.read!(@external_resource)

  @spec html() :: String.t()
  def html, do: @html
end
