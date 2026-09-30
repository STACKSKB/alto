defmodule Alto.Contrib.Providers.ModelMetadata do
  @moduledoc false
  def input_modalities(model) when is_map(model) do
    value =
      model[:input_modalities] || model["input_modalities"] || model["inputModalities"] ||
        get_in(model, ["architecture", "input_modalities"])

    Alto.InputModalities.from_model(%{input_modalities: value})
  end

  def input_modalities(_), do: nil
end
