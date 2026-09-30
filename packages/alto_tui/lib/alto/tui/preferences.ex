defmodule Alto.TUI.Preferences do
  @moduledoc "Remember the provider and model selection independently of task history."

  alias Alto.TUI.Catalog
  alias Alto.Storage

  @max_bytes 64_000

  def load(opts) do
    Storage.read_json(path(opts), @max_bytes, %{}, fn value ->
      is_map(value) and
        Enum.all?(value, fn {key, item} -> is_binary(key) and is_binary(item) end)
    end)
  end

  def model(preferences, state), do: preferences[model_key(state)]

  def save(state) do
    changes = %{
      "provider" => state.selected_provider_id,
      "backend" => to_string(state.selected_backend)
    }

    changes = Map.put(changes, model_key(state), state.selected_model)
    changes = Map.reject(changes, fn {_, value} -> is_nil(value) or value == "" end)

    Storage.update_json(
      path(state.catalog_opts),
      @max_bytes,
      fn -> load(state.catalog_opts) end,
      fn current ->
        next = Map.merge(current, changes)
        {:ok, next, next}
      end
    )
  end

  defp model_key(state),
    do: JSON.encode!([to_string(state.selected_backend), state.selected_provider_id])

  defp path(opts),
    do: Keyword.get(opts, :path, Catalog.default_path(opts)) <> ".preferences.json"
end
