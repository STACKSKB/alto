defmodule Alto.Search.Backend do
  @moduledoc """
  Backend contract for the model-facing `search_files` tool.

  Backends are trusted harness components. They may use native traversal,
  ripgrep, an index, or another implementation, but must return bounded,
  JSON-encodable results and must not widen the tool's declared authority.
  """

  alias Alto.Tool.Context

  @type request :: %{
          required(:query) => String.t(),
          required(:path) => String.t(),
          required(:case_sensitive) => boolean()
        }

  @callback search(request(), Context.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
