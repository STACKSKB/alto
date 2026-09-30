defmodule Alto.InputModalities do
  @moduledoc "Model-specific input capabilities, checked before provider dispatch."
  @modalities ~w(text image audio video file)

  def from_model(model) when is_map(model) do
    value =
      model[:input_modalities] || model["input_modalities"] || model["inputModalities"] ||
        get_in(model, ["architecture", "input_modalities"])

    if is_list(value), do: Enum.filter(value, &(&1 in @modalities)) |> Enum.uniq()
  end

  def from_model(_), do: nil

  @doc "Bind catalog capabilities to the chosen model; flags never follow a model switch."
  def bind(options, model, metadata \\ nil) do
    modalities =
      from_model(metadata) ||
        get_in(Keyword.get(options, :model_input_modalities, %{}), [model]) ||
        if(options[:model] == model and not is_nil(model),
          do: configured(options),
          else: ["text"]
        )

    options |> Keyword.put(:model, model) |> Keyword.put(:input_modalities, modalities)
  end

  @doc "Explicit modalities override legacy single-model image/file declarations. Audio is opt-in."
  def configured(options) do
    case Keyword.fetch(options, :input_modalities) do
      {:ok, values} when is_list(values) ->
        Enum.filter(values, &(&1 in @modalities))

      {:ok, _} ->
        []

      :error ->
        ["text"] ++
          if(options[:supports_images], do: ["image"], else: []) ++
          if(options[:supports_files], do: ["file"], else: [])
    end
  end

  def modality(%{"type" => "image"}), do: "image"
  def modality(%{"type" => "file", "media_type" => "image/" <> _}), do: "image"
  def modality(%{"type" => "file", "media_type" => "audio/" <> _}), do: "audio"
  def modality(%{"type" => "file", "media_type" => "video/" <> _}), do: "video"
  def modality(%{"type" => "file"}), do: "file"
  def modality(_), do: nil

  def required(%Alto.Content{blocks: blocks}), do: required(blocks)

  def required(blocks) when is_list(blocks),
    do: blocks |> Enum.map(&modality/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  def required(_), do: []

  def check(required, supported) do
    case Enum.find(required, &(&1 not in supported)) do
      nil -> :ok
      modality -> {:error, error(modality)}
    end
  end

  def check_content(content, options), do: check(required(content), configured(options))

  def check_request(request, provider, options) do
    required =
      Map.get(request, :messages, []) |> Enum.flat_map(&required(&1["content"])) |> Enum.uniq()

    if required == [] do
      :ok
    else
      description = provider.describe(Alto.Provider.options(options))
      declared = from_model(description)

      defaults =
        configured(
          options ++ [supports_images: description[:vision], supports_files: description[:files]]
        )

      check(
        required,
        if(Keyword.has_key?(options, :input_modalities),
          do: configured(options),
          else: declared || defaults
        )
      )
    end
  end

  def error("image"), do: :model_does_not_support_images
  def error("audio"), do: :model_does_not_support_audio
  def error("video"), do: :model_does_not_support_video
  def error("file"), do: :model_does_not_support_files
end
