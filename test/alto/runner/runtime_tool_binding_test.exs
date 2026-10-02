defmodule Alto.Runner.RuntimeToolBindingTest do
  use ExUnit.Case, async: true
  alias Alto.TestSupport.EchoTool

  defmodule Relay do
    use Alto.Tool,
      name: :relay,
      runtime_operation: :spawn_agents,
      execution_mode: :exclusive,
      approval: :required

    def options, do: %{}
    def schema(%{max_children: limit}) when limit > 0, do: EchoTool.schema([])

    def prepare(arguments, _, _) do
      {:ok, %{agents: [%{id: "child", task: arguments, loop: Alto.rule_loop(steps: ["echo"])}]},
       %{}}
    end

    def run(_, _, _), do: raise("the runtime must own delegation")
  end

  defmodule RetainedDirectory do
    @behaviour Alto.Resource
    defstruct [:path, :observer]

    def prepare(resource, _cwd), do: {:ok, resource.path}
    def create(_resource, _snapshot, _identity), do: {:ok, %{id: "owned", revision: 1}}

    def use(resource, id, revision, execute) do
      send(resource.observer, {:resource_used, id})
      {:ok, execute.(%{"cwd" => resource.path}), %{id: id, revision: revision, status: "worked"}}
    end

    def resume(_, _, _, _, _), do: {:error, :not_supported}

    def freeze(resource, id, revision) do
      send(resource.observer, {:resource_frozen, id})
      {:ok, %{id: id, revision: revision, status: "frozen"}}
    end

    def get(_, id), do: {:ok, %{id: id, revision: 1, status: "worked"}}
    def resource_identity(resource), do: {:ok, %{"directory" => resource.path}}
  end

  defmodule ReplacementDirectory do
    @behaviour Alto.Resource
    defstruct [:path, :observer]

    defdelegate prepare(resource, cwd), to: RetainedDirectory
    defdelegate create(resource, snapshot, identity), to: RetainedDirectory
    defdelegate use(resource, id, revision, execute), to: RetainedDirectory
    defdelegate resume(resource, id, revision, admit, execute), to: RetainedDirectory
    defdelegate freeze(resource, id, revision), to: RetainedDirectory
    defdelegate get(resource, id), to: RetainedDirectory
    defdelegate resource_identity(resource), to: RetainedDirectory
  end

  test "a separately named tool delegates under the same approval and inherited authority" do
    options = [
      loop: Alto.rule_loop(steps: ["relay"], subagents: Alto.Subagents.bounded(max_depth: 1)),
      tools: [Relay, EchoTool],
      agent_prepare: fn prepared, _, _ -> {:ok, prepared} end,
      approval: :approve
    ]

    result = Alto.run(%{"value" => "bound"}, options)
    assert result.status == :ok
    assert [%{results: [%{id: "child"} = child]}] = result.output
    assert child.output == [%{echo: "bound"}]

    denied = Alto.run(%{"value" => "bound"}, Keyword.put(options, :approval, {:deny, :policy}))
    assert denied.status == :error
    assert denied.reason == {:rule_step_failed, 1, "relay", {:approval_denied, :policy}}
  end

  test "owned child execution uses a host resource without knowing its implementation" do
    resource = %RetainedDirectory{path: File.cwd!(), observer: self()}

    result =
      Alto.run(%{"value" => "retained"},
        loop:
          Alto.rule_loop(
            steps: ["relay"],
            subagents: Alto.Subagents.bounded(max_depth: 1, workspaces: resource)
          ),
        tools: [Relay, EchoTool],
        agent_prepare: fn prepared, _, _ -> {:ok, prepared} end,
        approval: :approve
      )

    assert result.status == :ok

    assert [%{results: [%{workspace: %{status: "frozen"}, output: [%{echo: "retained"}]}]}] =
             result.output

    assert_received {:resource_used, "owned"}
    assert_received {:resource_frozen, "owned"}
  end

  test "approval checkpoints bind the retained resource implementation as well as its identity" do
    resource = %RetainedDirectory{path: File.cwd!(), observer: self()}
    replacement = %ReplacementDirectory{path: resource.path, observer: self()}

    options = fn resource ->
      [
        loop:
          Alto.rule_loop(
            steps: ["relay"],
            subagents: Alto.Subagents.bounded(max_depth: 1, workspaces: resource)
          ),
        tools: [Relay, EchoTool],
        approval: :suspend,
        checkpoint_version: "resource-v1"
      ]
    end

    assert %Alto.Runner.Result{status: :suspended} =
             suspended = Alto.run(%{"value" => "retained"}, options.(resource))

    resume = fn resource ->
      Alto.run(
        %{"value" => "retained"},
        Keyword.put(options.(resource), :checkpoint, {suspended.checkpoint, :approve})
      )
    end

    assert %Alto.Runner.Result{status: :error, reason: :checkpoint_mismatch} =
             resume.(replacement)

    refute_received {:resource_used, _}
    assert %Alto.Runner.Result{status: :ok} = resume.(resource)
    assert_received {:resource_used, "owned"}
  end
end
