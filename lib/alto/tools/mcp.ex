defmodule Alto.Tools.MCP do
  @moduledoc """
  Declarative adapter from one external MCP tool to an Alto tool.

  Each configured instance supplies its Alto-facing name and the remote tool
  name. Its schema may be supplied explicitly (recommended for workspace-scoped
  servers such as FFF), or discovered from `tools/list` when the server has a
  fixed working directory. Execution remains inside Alto's timeout, result-size,
  event, and approval boundaries.
  """

  @behaviour Alto.Tool

  alias Alto.External.MCP.Client
  alias Alto.Tool.Context

  @impl true
  def name(opts), do: Keyword.fetch!(opts, :name)

  @impl true
  def schema(opts) do
    case Keyword.fetch(opts, :schema) do
      {:ok, schema} when is_map(schema) ->
        schema

      {:ok, other} ->
        raise ArgumentError, "MCP tool schema must be a map, got: #{inspect(other)}"

      :error ->
        discover_schema!(opts)
    end
  end

  @impl true
  def execution_mode(opts), do: Keyword.get(opts, :execution_mode, :parallel)

  @impl true
  def approval(opts), do: Keyword.get(opts, :approval, :required)

  @impl true
  def run(arguments, %Context{} = context, opts) do
    server_opts = resolve_server!(opts, context.cwd)

    timeout =
      Keyword.get(opts, :request_timeout, Keyword.get(server_opts, :request_timeout, 30_000))

    with {:ok, client} <- Client.ensure_started(server_opts),
         {:ok, result} <- Client.call_tool(client, remote_name(opts), arguments, timeout) do
      {:ok, result}
    end
  end

  defp discover_schema!(opts) do
    server_opts = Keyword.fetch!(opts, :server)

    if Keyword.get(server_opts, :cwd) == :workspace do
      raise ArgumentError,
            "workspace-scoped MCP tools require an explicit schema because no workspace exists during configuration"
    end

    with {:ok, client} <- Client.ensure_started(server_opts),
         {:ok, tools} <- Client.list_tools(client),
         %{} = tool <- Enum.find(tools, &(&1["name"] == remote_name(opts))),
         %{} = input_schema <- tool["inputSchema"] do
      %{
        description: tool["description"] || "External MCP tool #{remote_name(opts)}",
        parameters: input_schema
      }
    else
      nil -> raise ArgumentError, "MCP tool #{remote_name(opts)} was not advertised"
      {:error, reason} -> raise ArgumentError, "MCP discovery failed: #{inspect(reason)}"
      _other -> raise ArgumentError, "MCP tool #{remote_name(opts)} advertised an invalid schema"
    end
  end

  defp resolve_server!(opts, workspace) do
    opts
    |> Keyword.fetch!(:server)
    |> Keyword.update(:cwd, workspace, fn
      :workspace -> workspace
      cwd -> cwd
    end)
  end

  defp remote_name(opts), do: Keyword.get(opts, :remote_name, Atom.to_string(name(opts)))
end
