defmodule Alto.Examples.DocumentIntakeTest do
  use ExUnit.Case, async: false

  import Bitwise

  Code.require_file("../../examples/document_intake/lib/intake.ex", __DIR__)
  Code.require_file("../../examples/document_intake/lib/cli.ex", __DIR__)

  defmodule FakeProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_called, request})

      {:ok,
       %{
         message:
           ~s|{"identity":"../../escape","title":"Recovered title","summary":"Recovered summary","fields":{"vendor":"=SUM(A1:A2)"}}|,
         tool_calls: []
       }}
    end
  end

  defmodule InvalidSchemaProvider do
    @behaviour Alto.Provider
    def describe(_opts), do: %{}
    def stream(_request, _sink, _opts), do: {:ok, %{message: ~s|{"fields":[]}|, tool_calls: []}}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-doc-example-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "source reads reject oversized documents before extraction", %{dir: dir} do
    File.mkdir_p!(dir)
    path = Path.join(dir, "large.md")
    File.write!(path, String.duplicate("x", 1_000_001))
    assert {:error, {:input_too_large, 1_000_000}} = DocumentIntake.read_source(path)
  end

  test "extracts deterministic markdown and reruns deduplicate", %{dir: dir} do
    text = "# Document 42\n\nsummary: Vendor document\n\n- vendor: Acme\n- total: 42.00\n"
    assert {:ok, record} = DocumentIntake.extract(text)
    assert record["title"] == "Document 42"
    assert record["fields"] == %{"vendor" => "Acme", "total" => "42.00"}

    assert {:ok, first} = DocumentIntake.write_artifacts(record, dir)
    assert first.version == 1
    assert File.dir?(Path.dirname(first.json))
    assert File.exists?(first.json) and File.exists?(first.csv)
    assert (File.stat!(dir).mode &&& 0o777) == 0o700
    assert (File.stat!(first.json).mode &&& 0o777) == 0o600
    assert (File.stat!(first.csv).mode &&& 0o777) == 0o600

    assert {:ok, duplicate} = DocumentIntake.write_artifacts(record, dir)
    assert duplicate.version == 1
    assert duplicate.duplicate? == true
    assert File.ls!(dir) |> Enum.count(&String.ends_with?(&1, ".json")) == 0
  end

  test "ambiguous input requires a configured resolver" do
    assert {:error, :llm_required_for_ambiguous_input} =
             DocumentIntake.extract("- vendor: Acme\n")
  end

  test "configured Alto provider is called and cannot replace identity", %{dir: dir} do
    text = "- vendor: Acme\n"

    assert {:ok, record} =
             DocumentIntake.extract(text,
               provider: {FakeProvider, test_pid: self()},
               state_dir: dir
             )

    assert record["identity"] == DocumentIntake.candidate(text)["identity"]
    assert record["identity"] =~ ~r/\A[0-9a-f]{24}\z/
    assert record["title"] == "Recovered title"
    assert_receive {:provider_called, request}
    assert request.messages |> List.last() |> Map.fetch!("content") =~ "Return JSON only"
    assert {:ok, persisted} = DocumentIntake.load_candidate(record["identity"], dir)
    assert Map.take(persisted, Map.keys(record)) == record
    assert persisted["schema_version"] == 1
  end

  test "invalid provider schema is rejected while candidate state remains", %{dir: dir} do
    assert {:error, :invalid_llm_schema} =
             DocumentIntake.extract("- vendor: Acme\n",
               provider: InvalidSchemaProvider,
               state_dir: dir
             )

    identity = DocumentIntake.candidate("- vendor: Acme\n")["identity"]

    assert {:ok, %{"identity" => ^identity, "title" => nil}} =
             DocumentIntake.load_candidate(identity, dir)
  end

  test "operator correction creates a new version with provenance", %{dir: dir} do
    record = DocumentIntake.candidate("# Document\n\nsummary: Original\n")
    assert {:ok, first} = DocumentIntake.write_artifacts(record, dir)
    assert {:ok, corrected} = DocumentIntake.correct(record, %{"summary" => "Corrected"})
    assert corrected["identity"] == record["identity"]
    assert corrected["provenance"]["kind"] == "human_correction"
    assert {:ok, second} = DocumentIntake.write_artifacts(corrected, dir)
    assert second.version == first.version + 1
    assert JSON.decode!(File.read!(second.json))["provenance"]["kind"] == "human_correction"
  end

  test "reconcile resumes a persisted candidate", %{dir: dir} do
    record = DocumentIntake.candidate("- vendor: Acme\n")
    assert :ok = DocumentIntake.persist_candidate(record, dir)

    assert {:ok, %{version: 1}} =
             DocumentIntake.reconcile(record["identity"], dir, %{
               "title" => "Document",
               "summary" => "Acme document"
             })

    assert {:ok, persisted} = DocumentIntake.load_candidate(record["identity"], dir)
    assert persisted["title"] == "Document"
  end

  test "a prior corrected candidate is retained on rerun", %{dir: dir} do
    text = "- vendor: Acme\n"
    candidate = DocumentIntake.candidate(text)

    assert {:ok, corrected} =
             DocumentIntake.correct(candidate, %{
               "title" => "Document",
               "summary" => "Acme document"
             })

    assert :ok = DocumentIntake.persist_candidate(corrected, dir)
    assert {:ok, rerun} = DocumentIntake.extract(text, state_dir: dir)
    assert rerun["title"] == "Document"
    assert rerun["provenance"]["kind"] == "human_correction"
  end

  test "CLI corrections persist for deterministic documents across reruns", %{dir: dir} do
    text = "# Document\n\nsummary: Original\n"
    corrections = %{"summary" => "Corrected"}

    assert {:ok, corrected} = DocumentIntakeCLI.extract_or_correct(text, corrections, dir, nil)
    assert corrected["summary"] == "Corrected"

    assert {:ok, rerun} = DocumentIntakeCLI.extract_or_correct(text, %{}, dir, nil)
    assert rerun["summary"] == "Corrected"
    assert rerun["provenance"]["kind"] == "human_correction"
  end

  test "concurrent publication emits one version and a complete pair", %{dir: dir} do
    record = DocumentIntake.candidate("# Concurrent\n\nsummary: Same\n")

    results =
      1..8
      |> Task.async_stream(fn _ -> DocumentIntake.write_artifacts(record, dir) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{version: 1}}, &1))
    [bundle] = Path.wildcard(Path.join(dir, "document-*-v1"))
    assert File.exists?(Path.join(bundle, "document.json"))
    assert File.exists?(Path.join(bundle, "document.csv"))
  end

  test "failed publication cleans its temporary directory and can recover", %{dir: dir} do
    record = DocumentIntake.candidate("# Retry\n\nsummary: Retry me\n")

    assert {:error, :injected_failure} =
             DocumentIntake.write_artifacts(record, dir,
               before_publish: fn _temporary, _final -> {:error, :injected_failure} end
             )

    assert Path.wildcard(Path.join(dir, "*.tmp")) == []
    assert {:ok, %{version: 1}} = DocumentIntake.write_artifacts(record, dir)
  end

  test "an incomplete bundle is reported for operator reconciliation", %{dir: dir} do
    record = DocumentIntake.candidate("# Partial\n\nsummary: Pair\n")
    assert {:ok, %{json: json_path, csv: csv_path}} = DocumentIntake.write_artifacts(record, dir)
    assert :ok = File.rm(csv_path)
    assert {:error, :incomplete_artifact} = DocumentIntake.write_artifacts(record, dir)
    assert File.exists?(json_path)
  end

  test "CSV contains fields and escapes formula values", %{dir: dir} do
    record = DocumentIntake.candidate("# CSV\n\nsummary: Safe\n\n- amount: =SUM(A1:A2)\n")
    assert {:ok, %{csv: csv_path}} = DocumentIntake.write_artifacts(record, dir)
    csv = File.read!(csv_path)
    assert csv =~ "fields"
    assert csv =~ "'=SUM(A1:A2)"
  end

  test "identity must be lower-case hex and is safe for paths" do
    assert {:error, :invalid_document_schema} =
             DocumentIntake.validate(%{
               "identity" => "../../escape",
               "title" => "Title",
               "summary" => "Summary",
               "fields" => %{},
               "source_text" => "source"
             })
  end
end
