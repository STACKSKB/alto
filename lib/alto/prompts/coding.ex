defmodule Alto.Prompts.Coding do
  @moduledoc "The shipped coding-agent prompt builder."

  @behaviour Alto.Prompt.Builder

  @tool_guidance "Use the provided tools when you need facts from the workspace. Tool results are bounded, so continue reads with offsets when necessary."
  @no_tools "No workspace tools are available. Do not claim to have inspected or changed the workspace."
  @read_only "This run is read-only. Explain any proposed changes instead of claiming to have written them."
  @write_enabled "Workspace editing tools are enabled. Prefer exact edits for existing files and make only changes required by the user's task."
  @command_enabled "The run_command tool uses the command executor configured by the harness. Shell syntax is interpreted only when a shell is explicitly selected. Use it for focused verification."
  @command_disabled "Command execution is disabled for this run."
  @finish "Keep working until the task is answered or completed, then return a concise final response."

  @impl true
  def build(%{cwd: cwd, tools: tools} = context, _opts) do
    capabilities = capabilities(tools)

    [
      base(cwd),
      project_fragment(Map.get(context, :project_instructions)),
      workspace_fragment(capabilities.workspace),
      command_fragment(capabilities.command),
      @finish
    ]
    |> List.flatten()
    |> Alto.Prompt.render()
  end

  @doc "The identity and workspace fragment used by the coding prompt."
  @spec base(binary()) :: binary()
  def base(cwd) do
    "You are a coding agent running in the Alto harness.\nThe workspace root is #{cwd}."
  end

  defp capabilities(tools) do
    names = MapSet.new(tools, &tool_name/1)

    %{
      workspace: workspace_capability(names),
      command: MapSet.member?(names, :run_command)
    }
  end

  defp tool_name({module, opts}) when is_atom(module) and is_list(opts) do
    if function_exported?(module, :name, 1), do: module.name(opts), else: module.name()
  end

  defp tool_name(module) when is_atom(module), do: module.name()

  defp workspace_capability(names) do
    cond do
      MapSet.member?(names, :edit_file) or MapSet.member?(names, :write_file) ->
        :write

      MapSet.member?(names, :run_command) ->
        :other_tools

      MapSet.size(names) > 0 and
          Enum.all?(names, &(&1 in [:list_files, :read_file, :search_files])) ->
        :read_only

      MapSet.size(names) > 0 ->
        :other_tools

      true ->
        :none
    end
  end

  defp workspace_fragment(:write), do: @tool_guidance <> "\n" <> @write_enabled
  defp workspace_fragment(:read_only), do: @tool_guidance <> "\n" <> @read_only
  defp workspace_fragment(:other_tools), do: @tool_guidance
  defp workspace_fragment(:none), do: @no_tools

  # Project instructions are user-owned, versionable workspace text resolved
  # and bounded by Alto.Project; they are rendered verbatim.
  defp project_fragment(nil), do: []

  defp project_fragment(%{file: file, instructions: instructions, truncated: truncated?}) do
    marker = if truncated?, do: "\n[alto: project instructions truncated]", else: ""

    [
      "The workspace provides project instructions (#{file}). Treat them as user-owned guidance for this repository:\n\n" <>
        instructions <> marker
    ]
  end

  defp command_fragment(true), do: @command_enabled
  defp command_fragment(false), do: @command_disabled
end
