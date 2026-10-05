# From packages/alto_tui: mix run ../../scripts/beam_append_bench.exs
# Synthetic data only. Time and backing size do not prove whether an append copied.
defmodule AltoAppendBench do
  def owned(count), do: Enum.reduce(1..count, "", fn _, text -> text <> "text" end)

  def sample(fun) do
    {us, text} = :timer.tc(fun)
    %{us: us, bytes: byte_size(text), backing_bytes: :binary.referenced_byte_size(text)}
  end
end

for count <- [4096, 8192, 16_384] do
  samples = for _ <- 1..5, do: AltoAppendBench.sample(fn -> AltoAppendBench.owned(count) end)
  IO.inspect(%{deltas: count, binary_append_samples: samples})
end

alias Alto.TUI.State

for count <- [4096, 8192] do
  samples =
    for _ <- 1..5 do
      AltoAppendBench.sample(fn ->
        state =
          Enum.reduce(1..count, %State{textarea: nil, run_options: [], catalog_opts: []}, fn _,
                                                                                             state ->
            State.append_assistant_delta(state, nil, "text")
          end)

        state.stream_tails[:scratch].entry.text
      end)
    end

  IO.inspect(%{deltas: count, tui_append_samples: samples})
end
