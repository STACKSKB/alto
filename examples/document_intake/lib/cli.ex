defmodule DocumentIntakeCLI do
  @moduledoc false

  def extract_or_correct(text, corrections, state_dir, config) do
    extract_opts = [state_dir: state_dir] ++ if(config, do: [config: config], else: [])

    case DocumentIntake.extract(text, extract_opts) do
      {:ok, record} when corrections == %{} ->
        {:ok, record}

      {:ok, record} ->
        with {:ok, corrected} <- DocumentIntake.correct(record, corrections),
             :ok <- DocumentIntake.persist_candidate(corrected, state_dir) do
          {:ok, corrected}
        end

      {:error, :llm_required_for_ambiguous_input} when corrections != %{} ->
        with {:ok, corrected} <-
               DocumentIntake.candidate(text) |> DocumentIntake.correct(corrections),
             :ok <- DocumentIntake.persist_candidate(corrected, state_dir) do
          {:ok, corrected}
        end

      other ->
        other
    end
  end

  def parse_corrections(flags), do: parse_corrections(flags, %{}, nil)

  defp parse_corrections([], corrections, config_path), do: {:ok, corrections, config_path}

  defp parse_corrections(["--title", value | rest], corrections, config_path),
    do: parse_corrections(rest, Map.put(corrections, "title", value), config_path)

  defp parse_corrections(["--summary", value | rest], corrections, config_path),
    do: parse_corrections(rest, Map.put(corrections, "summary", value), config_path)

  defp parse_corrections(["--config", path | rest], corrections, _config_path),
    do: parse_corrections(rest, corrections, path)

  defp parse_corrections(["--field", value | rest], corrections, config_path) do
    case String.split(value, "=", parts: 2) do
      [key, field_value] ->
        fields =
          Map.update(
            Map.get(corrections, "fields", %{}),
            String.downcase(key),
            field_value,
            fn _ -> field_value end
          )

        parse_corrections(rest, Map.put(corrections, "fields", fields), config_path)

      _ ->
        {:error, {:invalid_field, value}}
    end
  end

  defp parse_corrections([flag | _rest], _corrections, _config_path),
    do: {:error, {:unknown_option, flag}}

  def load_config(nil), do: {:ok, nil}
  def load_config(path), do: Alto.Config.load(path)
end
