#!/usr/bin/env elixir
Application.ensure_all_started(:alto)
Code.require_file("lib/intake.ex", __DIR__)
Code.require_file("lib/cli.ex", __DIR__)

case System.argv() do
  [input, output_dir | flags] ->
    with {:ok, text} <- DocumentIntake.read_source(input),
         {:ok, corrections, config_path} <- DocumentIntakeCLI.parse_corrections(flags),
         {:ok, config} <- DocumentIntakeCLI.load_config(config_path),
         result <- DocumentIntakeCLI.extract_or_correct(text, corrections, output_dir, config),
         {:ok, record} <- result,
         {:ok, artifact} <- DocumentIntake.write_artifacts(record, output_dir) do
      IO.inspect(artifact, label: "artifact")
    else
      {:error, :llm_required_for_ambiguous_input} ->
        IO.puts(:stderr, "ambiguous input: rerun with --title and --summary to correct it")
        System.halt(3)

      {:error, reason} ->
        IO.puts(:stderr, "document intake failed: #{inspect(reason)}")
        System.halt(1)
    end

  _ ->
    IO.puts(
      :stderr,
      "usage: mix run examples/document_intake/run.exs INPUT.md OUTPUT_DIR [--config CONFIG.exs] [--title TEXT] [--summary TEXT] [--field KEY=VALUE]"
    )

    System.halt(2)
end
