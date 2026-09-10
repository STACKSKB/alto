defmodule Alto.Prompt.Builder do
  @moduledoc "Contract for replaceable system-prompt builders."

  @type context :: %{
          required(:cwd) => binary(),
          required(:tools) => [Alto.Tool.spec()],
          optional(:project_instructions) => Alto.Project.instructions() | nil
        }

  @callback build(context(), keyword()) :: binary()
end
