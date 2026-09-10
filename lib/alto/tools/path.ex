defmodule Alto.Tools.Path do
  @moduledoc false

  @spec resolve(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def resolve(path, cwd) when is_binary(path) and is_binary(cwd) do
    expanded_root = Path.expand(cwd)
    expanded_path = Path.expand(path, expanded_root)
    relative = Path.relative_to(expanded_path, expanded_root)

    case :filelib.safe_relative_path(
           String.to_charlist(relative),
           String.to_charlist(expanded_root)
         ) do
      :unsafe -> {:error, {:path_outside_workspace, path}}
      safe -> {:ok, Path.join(expanded_root, List.to_string(safe))}
    end
  end

  def resolve(path, _cwd), do: {:error, {:invalid_path, path}}
end
