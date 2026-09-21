defmodule Alto.AgentIdentity do
  @moduledoc "Execution-tree identity shared by runs, checkpoints and workspaces."

  @type t :: %{root_run_id: String.t(), path: [String.t()]}

  @spec valid?(term()) :: boolean()
  def valid?(%{root_run_id: root, path: path} = identity) when is_list(path) do
    map_size(identity) == 2 and valid_part?(root) and length(path) <= 64 and
      Enum.all?(path, &valid_part?/1)
  end

  def valid?(_), do: false

  defp valid_part?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)
end
