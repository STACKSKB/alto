# Run from packages/alto_tui: mix run ../../scripts/optimization_experiments.exs
# Offline paired comparisons against the audited revision; no provider calls.
defmodule AltoOptimizationExperiments do
  def load_baseline(path, module) do
    {source, 0} = System.cmd("git", ["show", "4517152:" <> path])
    name = inspect(module)
    baseline = "AltoExperimentBaseline." <> String.replace_prefix(name, "Alto.", "")

    source
    |> String.replace("defmodule " <> name, "defmodule " <> baseline)
    |> Code.compile_string()

    Module.concat([baseline])
  end

  def paired(label, before, after_fun) do
    samples =
      for n <- 1..5 do
        funcs =
          if rem(n, 2) == 0,
            do: [after: after_fun, before: before],
            else: [before: before, after: after_fun]

        Map.new(funcs, fn {key, fun} ->
          value =
            Task.async(fn ->
              Alto.TUI.Cache.configure(16_000_000)
              {us, result} = :timer.tc(fun)
              %{ms: us / 1000, value: result}
            end)
            |> Task.await(120_000)

          {key, value}
        end)
      end

    medians =
      Map.new([:before, :after], fn key ->
        {key, samples |> Enum.map(& &1[key].ms) |> Enum.sort() |> Enum.at(2)}
      end)

    IO.puts(JSON.encode!(%{probe: label, median_ms: medians, samples: samples}))
  end

  def run do
    markdown = load_baseline("packages/alto_tui/lib/alto/tui/markdown.ex", Alto.TUI.Markdown)

    transcript =
      load_baseline("packages/alto_tui/lib/alto/tui/transcript.ex", Alto.TUI.Transcript)

    diff = load_baseline("lib/alto/tools/unified_diff.ex", Alto.Tools.UnifiedDiff)
    Alto.TUI.Markdown.tail("warm", 84, 40)
    markdown.tail("warm", 84, 40)

    for size <- [4000, 8190, 8200, 12_000, 16_000, 64_000] do
      source = String.duplicate("word ", div(size, 5))

      paired("markdown_tail_#{size}", fn -> length(markdown.tail(source, 84, 40).lines) end, fn ->
        length(Alto.TUI.Markdown.tail(source, 84, 40).lines)
      end)

      paired("markdown_tail_warm_#{size}", fn -> warm_tail(markdown, source) end, fn ->
        warm_tail(Alto.TUI.Markdown, source)
      end)
    end

    for {kind, source} <- [
          code: "```elixir\n" <> String.duplicate("  IO.puts(\"猫\")\n", 800) <> "```",
          table:
            "| Name | Evidence |\n| --- | --- |\n" <>
              Enum.map_join(1..400, "\n", &"| item #{&1} | some **evidence** |"),
          heading: "## " <> String.duplicate("long **heading** 猫 ", 800)
        ] do
      paired("markdown_#{kind}", fn -> length(markdown.tail(source, 84, 40).lines) end, fn ->
        length(Alto.TUI.Markdown.tail(source, 84, 40).lines)
      end)
    end

    entries = for n <- 1..200, do: %{kind: :user, text: "#{n}\n" <> String.duplicate("row\n", 98)}

    for {name, module} <- [before: transcript, after: Alto.TUI.Transcript] do
      Alto.TUI.Cache.clear()
      index = module.index(entries, 84)

      IO.puts(
        JSON.encode!(%{
          probe: "literal_index",
          variant: name,
          bytes: :erlang.external_size(index),
          cached:
            Enum.any?(Alto.TUI.Cache.stats().items, fn {{namespace, _}, _} ->
              namespace == {module, :indexes}
            end)
        })
      )
    end

    paired("literal_index_cold", fn -> transcript.index(entries, 84).rows end, fn ->
      Alto.TUI.Transcript.index(entries, 84).rows
    end)

    paired("literal_repeated_viewport", fn -> viewport(transcript, entries) end, fn ->
      viewport(Alto.TUI.Transcript, entries)
    end)

    for count <- [10, 250, 1000], mode <- [:disjoint, :shared] do
      before = Enum.map_join(1..count, "\n", &"before #{&1}")

      updated =
        if mode == :disjoint,
          do: Enum.map_join(1..count, "\n", &"after #{&1}"),
          else: before <> "\nadded"

      expected = diff.render("file", before, updated, 128)
      ^expected = Alto.Tools.UnifiedDiff.render("file", before, updated, 128)

      paired("diff_#{mode}_#{count}", fn -> diff.render("file", before, updated, 128) end, fn ->
        Alto.Tools.UnifiedDiff.render("file", before, updated, 128)
      end)
    end
  end

  defp warm_tail(module, source) do
    module.tail(source, 84, 40)
    {us, result} = :timer.tc(fn -> module.tail(source, 84, 40) end)
    %{warm_ms: us / 1000, rows: length(result.lines)}
  end

  defp viewport(module, entries) do
    index = module.index(entries, 84)
    {us, result} = :timer.tc(fn -> module.viewport(entries, 84, index.rows - 80, 40) end)
    %{viewport_ms: us / 1000, rows: length(result.lines)}
  end
end

AltoOptimizationExperiments.run()
