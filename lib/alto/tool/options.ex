defmodule Alto.Tool.Options do
  @moduledoc false

  # Tools share option validation mechanics, while their schemas and error tags
  # stay with the tool. Host composition owns the actual option values.
  def validate(opts, schema, error_tag) do
    if is_list(opts) and Keyword.keyword?(opts) do
      case NimbleOptions.validate(opts, schema) do
        {:ok, values} -> {:ok, Map.new(values)}
        {:error, reason} -> {:error, {error_tag, reason}}
      end
    else
      {:error, {error_tag, opts}}
    end
  end
end
