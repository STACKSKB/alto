defmodule Alto.Tools.ReadFile do
  @moduledoc "Bounded, workspace-confined file reads."

  @behaviour Alto.Tool

  alias Alto.Tool.Context
  alias Alto.Tools.Path, as: SafePath

  # The result includes path/offset/metadata and invalid UTF-8 is base64
  # expanded. Leave enough headroom for the runner's default native result
  # bound instead of advertising a content limit that can be rejected after
  # the read has already completed.
  @max_bytes 47_000

  @impl true
  def name, do: :read_file

  @impl true
  def schema do
    %{
      description: "Read a bounded byte range from a file inside the workspace.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Workspace-relative or in-workspace absolute path."
          },
          offset: %{type: "integer", minimum: 0, description: "Byte offset; defaults to 0."},
          limit: %{
            type: "integer",
            minimum: 1,
            maximum: @max_bytes,
            description: "Maximum bytes to read."
          }
        },
        required: ["path"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def execution_mode, do: :parallel

  @impl true
  def approval, do: :never

  @impl true
  def run(arguments, %Context{} = context) do
    path = Map.get(arguments, "path")
    offset = Map.get(arguments, "offset", 0)
    limit = Map.get(arguments, "limit", @max_bytes)

    with :ok <- valid_range(offset, limit),
         {:ok, resolved} <- SafePath.resolve(path, context.cwd) do
      case :file.open(String.to_charlist(resolved), [:read, :binary]) do
        {:ok, file} ->
          try do
            with {:ok, content} <- read(file, offset, limit) do
              {:ok, encode_content(path, offset, content, limit)}
            end
          after
            :file.close(file)
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp read(file, offset, limit) do
    with {:ok, _position} <- :file.position(file, offset) do
      case :file.read(file, limit + 1) do
        {:ok, content} -> {:ok, content}
        :eof -> {:ok, ""}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp encode_content(path, offset, content, limit) do
    {content, truncated?} =
      if byte_size(content) > limit,
        do: {binary_part(content, 0, limit), true},
        else: {content, false}

    if String.valid?(content) do
      %{path: path, offset: offset, content: content, truncated: truncated?}
    else
      %{
        path: path,
        offset: offset,
        content_base64: Base.encode64(content),
        encoding: "base64",
        truncated: truncated?
      }
    end
  end

  defp valid_range(offset, limit)
       when is_integer(offset) and offset >= 0 and is_integer(limit) and limit > 0 and
              limit <= @max_bytes,
       do: :ok

  defp valid_range(offset, limit), do: {:error, {:invalid_range, offset, limit}}
end
