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

  @doc "Return the three model-facing tool specs backed by one workspace-scoped FFF server."
  @spec tools(keyword()) :: [Alto.Tool.spec()]
  def tools(opts \\ []) do
    executable = Keyword.get(opts, :executable, "fff-mcp")
    args = Keyword.get(opts, :args, [])

    server = [
      command: executable,
      args: args,
      cwd: :workspace,
      startup_timeout: Keyword.get(opts, :startup_timeout, 30_000),
      request_timeout: Keyword.get(opts, :request_timeout, 30_000),
      max_message_bytes: Keyword.get(opts, :max_message_bytes, 2_000_000),
      max_pending_requests: Keyword.get(opts, :max_pending_requests, 128),
      max_ready_waiters: Keyword.get(opts, :max_ready_waiters, 128)
    ]

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
