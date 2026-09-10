defmodule Alto.Project do
  @moduledoc """
  Bounded discovery of project instructions for a workspace.

  Project instructions are explicit, versionable inputs (the design contract): read-only
  bounded text loaded from the workspace root, never executed and never
  project-local configuration. `alto.md` wins over `AGENTS.md` so an
  Alto-specific file can refine the generic agent file.
  """

  @default_files ["alto.md", "AGENTS.md"]
  @max_instruction_bytes 32_000

  @type instructions :: %{
          path: Path.t(),
          file: String.t(),
          instructions: String.t(),
          truncated: boolean()
        }

  @spec default_files() :: [String.t()]
  def default_files, do: @default_files

  @spec max_instruction_bytes() :: pos_integer()
  def max_instruction_bytes, do: @max_instruction_bytes

  @doc """
  Load the first instruction file found at the workspace root, bounded.

  Returns `{:ok, nil}` when no candidate exists, so callers can distinguish
  "no instructions" from a read failure. Content must be valid UTF-8; an
  oversized file is truncated on a code-point boundary with `truncated: true`.
  """
  @spec load(Path.t(), keyword()) :: {:ok, instructions() | nil} | {:error, term()}
  def load(cwd, opts \\ []) when is_binary(cwd) do
    files = Keyword.get(opts, :files, @default_files)
    max_bytes = Keyword.get(opts, :max_bytes, @max_instruction_bytes)

    Enum.find_value(files, {:ok, nil}, fn name ->
      case read_instructions(Path.join(cwd, name), max_bytes) do
        :missing -> nil
        {:ok, instructions} -> {:ok, instructions}
        {:error, reason} -> {:error, {name, reason}}
      end
    end)
  end

  defp read_instructions(path, max_bytes) do
    case File.read(path) do
      {:ok, content} ->
        with :ok <- validate_utf8(content) do
          {:ok, bounded(path, content, max_bytes)}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_utf8(content) do
    if String.valid?(content), do: :ok, else: {:error, :instructions_not_utf8}
  end

  defp bounded(path, content, max_bytes) when byte_size(content) <= max_bytes do
    %{
      path: path,
      file: Path.basename(path),
      instructions: content,
      truncated: false
    }
  end

  defp bounded(path, content, max_bytes) do
    %{
      path: path,
      file: Path.basename(path),
      instructions: truncate_to_code_point(binary_part(content, 0, max_bytes)),
      truncated: true
    }
  end

  defp truncate_to_code_point(kept) do
    if String.valid?(kept) do
      kept
    else
      # binary_part may cut the last code point; drop whole trailing bytes
      # until the remainder is valid UTF-8 again.
      truncate_to_code_point(binary_part(kept, 0, byte_size(kept) - 1))
    end
  end
end
