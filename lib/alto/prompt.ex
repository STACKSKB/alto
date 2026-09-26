defmodule Alto.Prompt do
  @moduledoc "Construction and rendering for replaceable system-prompt functions."

  @type context :: %{
          required(:cwd) => binary(),
          required(:tools) => [Alto.Tool.spec()],
          optional(:project_instructions) => Alto.Project.instructions() | nil
        }
  @type builder :: binary() | nil | (context() -> binary())

  @spec build(builder(), context()) :: binary() | nil
  def build(value, _context) when value in [nil, ""], do: nil
  def build(value, _context) when is_binary(value), do: value

  def build(builder, context) do
    prompt = builder.(context)
    true = is_binary(prompt)
    prompt
  end

  @doc "Render prompt fragments with stable separation."
  @spec render([binary()]) :: binary()
  def render(fragments), do: Enum.join(fragments, "\n") <> "\n"
end
