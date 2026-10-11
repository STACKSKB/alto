defmodule Alto.Contrib.Resident.Approvals.CodingTeam do
  @moduledoc """
  Opt-in coding-team policy: permit bounded file writes in an actively owned
  worker checkout; suspend the lead's effects for durable operator approval.
  Other approval-requiring worker tools are denied. Configure the same workspace
  manager in this policy, the team loop and the patch tools.
  """
  @doc "Build the approval classifier for a trusted workspace manager."
  def policy(opts), do: fn request, context -> decide(request, context, opts) end

  def decide(_request, %{agent_identity: %{path: []}}, _opts), do: :suspend

  def decide(
        %{tool: tool},
        %{cwd: cwd, agent_identity: %{path: [_ | _]} = identity},
        opts
      )
      when tool in ["write_file", "edit_file"] and is_binary(cwd) do
    id = cwd |> Path.dirname() |> Path.basename()

    with %Alto.Contrib.Workspaces{} = manager <- Keyword.get(opts, :manager),
         {:ok, %{status: "in_progress", workspace: workspace}} <-
           Alto.Contrib.Workspaces.get(manager, id),
         true <- cwd == Path.join([manager.root, id, "checkout"]),
         true <- workspace["cwd"] == cwd,
         true <- workspace["owner"] == Alto.Contrib.Protocol.encode_term(identity) do
      :approve
    else
      _ -> {:deny, :worker_workspace_not_owned}
    end
  end

  def decide(_, _, _), do: {:deny, :worker_tool_not_permitted}
end
