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
      case read_instructions(name, cwd, max_bytes) do
        :missing -> nil
        {:ok, instructions} -> {:ok, instructions}
        {:error, reason} -> {:error, {name, reason}}
      end
    end)
  end

  defp read_instructions(name, cwd, max_bytes) do
    with true <- (is_integer(max_bytes) and max_bytes > 0) or {:error, :invalid_max_bytes},
         {:ok, path} <- Alto.Tools.Path.resolve(name, cwd),
         {:ok, %{type: :regular}} <- File.stat(path) do
      File.open(path, [:read, :binary], fn io ->
        case IO.binread(io, max_bytes + 4) do
          :eof -> {:ok, bounded(path, "", max_bytes)}
          {:error, reason} -> {:error, reason}
          content -> decode_bounded(path, content, max_bytes)
        end
      end)
      |> case do
        {:ok, result} -> result
        error -> error
      end
    else
      {:error, :enoent} -> :missing
      {:ok, _stat} -> {:error, :instructions_not_regular}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_bounded(path, content, max_bytes) when byte_size(content) > max_bytes do
    # At most three trailing bytes can be an incomplete UTF-8 code point.
    # Never hide malformed bytes earlier in the retained prefix.
    prefix = binary_part(content, 0, max_bytes)

    case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
      kept when is_binary(kept) -> {:ok, %{bounded(path, kept, max_bytes) | truncated: true}}
      {:incomplete, kept, _tail} -> {:ok, %{bounded(path, kept, max_bytes) | truncated: true}}
      {:error, _kept, _tail} -> {:error, :instructions_not_utf8}
    end
  end

  defp decode_bounded(path, content, max_bytes) do
    case validate_utf8(content) do
      :ok -> {:ok, bounded(path, content, max_bytes)}
      error -> error
    end
  end

  defp validate_utf8(content) do
    if String.valid?(content), do: :ok, else: {:error, :instructions_not_utf8}
  end

  defp bounded(path, content, _max_bytes) do
    %{
      path: path,
      file: Path.basename(path),
      instructions: content,
      truncated: false
    }
  end
end
