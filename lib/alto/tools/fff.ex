defmodule Alto.Tools.FFF do
  @moduledoc """
  Thin Alto tool specifications for the external `fff-mcp` server.

  This module contains no search implementation. It supplies stable schemas to
  `Alto.Tools.MCP` so FFF can be started lazily in the active workspace and its
  in-memory index can remain resident across runs.
  """

  @file_schema %{
    description:
      "Frecency- and git-aware fuzzy path search using the external FFF index. Keep queries short; supports path prefixes and FFF glob constraints.",
    parameters: %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Fuzzy path query and optional FFF constraints."},
        maxResults: %{type: "number", minimum: 1, maximum: 100},
        cursor: %{type: "string", description: "Opaque cursor from a previous result page."}
      },
      required: ["query"],
      additionalProperties: false
    }
  }

  @grep_schema %{
    description:
      "Search file contents through the external FFF warm index. Put filename, directory, glob, and exclusion constraints inline before the query.",
    parameters: %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Content query."},
        maxResults: %{type: "number", minimum: 1, maximum: 100},
        output_mode: %{type: "string"},
        context: %{type: "number", minimum: 0, maximum: 100},
        cursor: %{type: "string", description: "Opaque cursor from a previous result page."}
      },
      required: ["query"],
      additionalProperties: false
    }
  }

  @multi_schema %{
    description:
      "Search several content patterns in one call through the external FFF warm index.",
    parameters: %{
      type: "object",
      properties: %{
        patterns: %{type: "array", items: %{type: "string"}, minItems: 1, maxItems: 50},
        constraints: %{
          type: "string",
          description: "FFF file constraints, such as '*.{ex,exs} !deps/'."
        },
        maxResults: %{type: "number", minimum: 1, maximum: 100},
        output_mode: %{type: "string"},
        context: %{type: "number", minimum: 0, maximum: 100},
        cursor: %{type: "string"}
      },
      required: ["patterns"],
      additionalProperties: false
    }
  }

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
