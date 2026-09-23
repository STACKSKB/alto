defmodule Alto.Tools.FFF do
  @moduledoc """
  Thin Alto tool specifications for the external `fff-mcp` server.

  This module contains no search implementation. It supplies stable schemas to
  `Alto.Tools.MCP` so FFF can be started lazily in the active workspace and its
  in-memory index can remain resident across runs.
  """

  @page_fields %{
    maxResults: %{type: "number", minimum: 1, maximum: 100},
    cursor: %{type: "string", description: "Opaque cursor from a previous result page."}
  }
  @content_fields Map.merge(@page_fields, %{
                    output_mode: %{type: "string"},
                    context: %{type: "number", minimum: 0, maximum: 100}
                  })

  @file_schema Alto.Tool.object_schema(
                 "Frecency- and git-aware fuzzy path search using the external FFF index. Keep queries short; supports path prefixes and FFF glob constraints.",
                 Map.merge(@page_fields, %{
                   query: %{
                     type: "string",
                     description: "Fuzzy path query and optional FFF constraints."
                   }
                 }),
                 ["query"]
               )

  @grep_schema Alto.Tool.object_schema(
                 "Search file contents through the external FFF warm index. Put filename, directory, glob, and exclusion constraints inline before the query.",
                 Map.put(@content_fields, :query, %{type: "string", description: "Content query."}),
                 ["query"]
               )

  @multi_schema Alto.Tool.object_schema(
                  "Search several content patterns in one call through the external FFF warm index.",
                  Map.merge(@content_fields, %{
                    patterns: %{
                      type: "array",
                      items: %{type: "string"},
                      minItems: 1,
                      maxItems: 50
                    },
                    constraints: %{
                      type: "string",
                      description: "FFF file constraints, such as '*.{ex,exs} !deps/'."
                    }
                  }),
                  ["patterns"]
                )

  @doc """
  Return three tools backed by one workspace-scoped FFF server.
  Options are MCP server options; `command` defaults to `fff-mcp` and `cwd`
  is always resolved from the active workspace.
  """
  @spec tools(keyword()) :: [Alto.Tool.spec()]
  def tools(opts \\ []) do
    server = opts |> Keyword.put_new(:command, "fff-mcp") |> Keyword.put(:cwd, :workspace)

    [
      spec(:fff_find_files, "find_files", @file_schema, server),
      spec(:fff_grep, "grep", @grep_schema, server),
      spec(:fff_multi_grep, "multi_grep", @multi_schema, server)
    ]
  end

  defp spec(name, remote_name, schema, server) do
    {Alto.Tools.MCP,
     name: name,
     remote_name: remote_name,
     schema: schema,
     server: server,
     approval: :never,
     execution_mode: :parallel}
  end
end
