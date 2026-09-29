# From the repository root: mix run scripts/harness_storage_bench.exs
# Synthetic data only; tmp filesystem/fsync timings depend on the host.
measure = fn label, count, fun ->
  {us, _} = :timer.tc(fn -> for _ <- 1..count, do: fun.() end)
  IO.inspect(%{operation: label, samples: count, average_ms: us / count / 1000})
end

dir = Path.join(System.tmp_dir!(), "alto-storage-bench-#{System.unique_integer([:positive])}")
opts = [session_dir: dir]

try do
  {:ok, id} = Alto.Session.create("benchmark", %{}, opts)
  event = Alto.Session.started_record(%{task: "benchmark"})

  measure.("durable append including lock and fsync", 50, fn ->
    :ok = Alto.Session.append(id, event, opts)
  end)

  messages =
    for n <- 1..400,
        do: %{"role" => "user", "content" => String.duplicate("sample content #{n} ", 100)}

  bytes = Alto.Context.Transcript.bytes(messages)
  IO.inspect(%{snapshot_bytes: bytes})

  measure.("persist whole transcript boundary", 10, fn ->
    {:ok, _} = Alto.Session.persist_settled(id, messages, bytes, opts)
  end)

  measure.("fetch atomic head", 20, fn ->
    {:ok, _} = Alto.Session.conversation(id, :latest, opts)
  end)

  measure.("resume with lock", 20, fn -> {:ok, _} = Alto.Session.resume_options(id, opts) end)
after
  File.rm_rf!(dir)
end
