defmodule Alto.Context.Reducers.Legacy do
  @moduledoc "Compatibility adapter for text-based reduce/request/decode callbacks."
  @behaviour Alto.Context.Reducer

  @impl true
  def compact(input, model, opts) do
    {module, options} = Keyword.fetch!(opts, :reducer)
    limit = input.max_summary_bytes

    result =
      if function_exported?(module, :reduce, 3) do
        module.reduce(input.text, limit, options)
      else
        with {:ok, request} <- module.request(input.text, limit, options),
             {:ok, completion} <- model.(request),
             do: module.decode(completion, limit, options)
      end

    case result do
      {:ok, content} when is_binary(content) and content != "" and byte_size(content) <= limit ->
        if String.valid?(content),
          do: {:ok, Alto.Context.Reducers.Summary.product(input, content)},
          else: {:error, :invalid_compaction_result}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_compaction_result}
    end
  end
end
