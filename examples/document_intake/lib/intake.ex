defmodule DocumentIntake do
  @moduledoc """
  A small, restartable document intake example.

  Parsing is deterministic first. An explicitly configured Alto provider may
  fill in missing fields, while the source-derived identity remains owned by
  this module for the lifetime of the document.
  """

  @schema_version 1
  @max_input_bytes 1_000_000
  @max_string_bytes 16_000
  @max_field_count 128
  @max_field_key_bytes 64
  @max_identity_bytes 24
  @max_candidate_file_bytes 4_000_000

  @doc "Read an input document without allocating beyond the accepted source limit."
  def read_source(path) do
    case bounded_read(path, @max_input_bytes) do
      {:error, :candidate_too_large} -> {:error, {:input_too_large, @max_input_bytes}}
      result -> result
    end
  end

  @doc "Extract a document, using an injected resolver or configured Alto provider for ambiguity."
  def extract(text, opts \\ [])

  def extract(text, opts) when is_binary(text) and is_list(opts) do
    if byte_size(text) > @max_input_bytes do
      {:error, {:input_too_large, @max_input_bytes}}
    else
      record = text |> candidate() |> resume_candidate(opts)

      with :ok <- maybe_persist_candidate(record, opts),
           {:ok, record} <- resolve_ambiguity(record, opts),
           :ok <- validate(record),
           :ok <- maybe_persist(record, opts) do
        {:ok, record}
      end
    end
  end

  def extract(_text, _opts), do: {:error, :text_must_be_string}

  @doc "Return the deterministic candidate without requiring missing fields to be resolved."
  def candidate(text) when is_binary(text) do
    text = text |> String.replace("\r\n", "\n") |> String.trim()
    deterministic(text)
  end

  def candidate(_text), do: {:error, :text_must_be_string}

  @doc "Apply an operator correction while preserving source identity and recording provenance."
  def correct(record, correction) when is_map(record) and is_map(correction) do
    with :ok <- valid_identity(Map.get(record, "identity")),
         :ok <- valid_correction(correction) do
      corrected =
        record
        |> Map.merge(Map.take(correction, ["title", "summary", "fields"]))
        |> Map.put("identity", record["identity"])
        |> Map.put("provenance", %{
          "kind" => "human_correction",
          "fields" => correction |> Map.keys() |> Enum.sort()
        })

      case validate(corrected) do
        :ok -> {:ok, corrected}
        error -> error
      end
    end
  end

  def correct(_record, _correction), do: {:error, :invalid_document_schema}

  @doc "Validate the complete persisted document shape and all size/path constraints."
  def validate(record) when is_map(record) do
    with :ok <- valid_identity(Map.get(record, "identity")),
         :ok <- valid_string(Map.get(record, "title"), :title, false),
         :ok <- valid_string(Map.get(record, "summary"), :summary, false),
         :ok <- valid_fields(Map.get(record, "fields")),
         :ok <- valid_source(Map.get(record, "source_text")),
         :ok <- valid_provenance(Map.get(record, "provenance")) do
      :ok
    else
      _ -> {:error, :invalid_document_schema}
    end
  end

  def validate(_record), do: {:error, :invalid_document_schema}

  @doc "Persist a candidate atomically so an interrupted operator run can be resumed."
  def persist_candidate(record, dir) when is_map(record) and is_binary(dir) do
    with :ok <- validate_candidate(record),
         :ok <- Alto.Storage.ensure_private_dir(dir, owned: true) do
      path = candidate_path(dir, record["identity"])

      Alto.Storage.with_lock(Path.join(dir, ".document-intake.lock"), fn ->
        write_private_json(path, Map.put(record, "schema_version", @schema_version))
      end)
    end
  end

  def persist_candidate(_record, _dir), do: {:error, :invalid_document_schema}

  @doc "Load a persisted candidate by its source-derived identity."
  def load_candidate(identity, dir) when is_binary(identity) and is_binary(dir) do
    with :ok <- valid_identity(identity),
         {:ok, body} <- bounded_read(candidate_path(dir, identity), @max_candidate_file_bytes),
         {:ok, record} <- JSON.decode(body),
         :ok <- validate_candidate(record) do
      {:ok, record}
    else
      {:error, :enoent} -> {:error, :candidate_not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_document_schema}
    end
  end

  def load_candidate(_identity, _dir), do: {:error, :invalid_identity}

  @doc "Resume an operator correction from persisted state and publish its next version."
  def reconcile(identity, dir, correction)
      when is_binary(identity) and is_binary(dir) and is_map(correction) do
    with {:ok, candidate} <- load_candidate(identity, dir),
         {:ok, corrected} <- correct(candidate, correction),
         :ok <- persist_candidate(corrected, dir),
         result <- write_artifacts(corrected, dir) do
      result
    end
  end

  def reconcile(_identity, _dir, _correction), do: {:error, :invalid_correction}

  @doc "Publish a JSON/CSV artifact bundle without exposing a half-written pair."
  def write_artifacts(record, dir, opts \\ [])

  def write_artifacts(record, dir, opts)
      when is_map(record) and is_binary(dir) and is_list(opts) do
    with :ok <- validate(record),
         :ok <- Alto.Storage.ensure_private_dir(dir, owned: true) do
      lock = Path.join(dir, ".document-intake.lock")
      Alto.Storage.with_lock(lock, fn -> publish_locked(record, dir, opts) end)
    end
  end

  def write_artifacts(_record, _dir, _opts), do: {:error, :invalid_document_schema}

  defp publish_locked(record, dir, opts) do
    identity = record["identity"]

    case find_existing(dir, record) do
      {:error, reason} ->
        {:error, reason}

      {:ok, artifact} ->
        {:ok, Map.put(artifact, :duplicate?, true)}

      :missing ->
        version = next_version(dir, identity)
        final_dir = Path.join(dir, "document-#{identity}-v#{version}")
        temporary_dir = Path.join(dir, ".document-#{identity}-v#{version}-#{unique_suffix()}.tmp")

        result =
          with :ok <- Alto.Storage.ensure_private_dir(temporary_dir, owned: true),
               json <- JSON.encode!(Map.put(record, "schema_version", @schema_version)),
               csv <- csv(record, version),
               :ok <-
                 Alto.Tools.AtomicWrite.write(
                   Path.join(temporary_dir, "document.json"),
                   json <> "\n",
                   0o600
                 ),
               :ok <-
                 Alto.Tools.AtomicWrite.write(
                   Path.join(temporary_dir, "document.csv"),
                   csv,
                   0o600
                 ),
               :ok <- publish_hook(opts, temporary_dir, final_dir),
               :ok <- File.rename(temporary_dir, final_dir) do
            {:ok,
             %{
               version: version,
               json: Path.join(final_dir, "document.json"),
               csv: Path.join(final_dir, "document.csv"),
               duplicate?: false
             }}
          end

        if match?({:ok, _}, result),
          do: result,
          else: cleanup_failed_publish(temporary_dir, result)
    end
  end

  defp publish_hook(opts, temporary_dir, final_dir) do
    case Keyword.get(opts, :before_publish) do
      fun when is_function(fun, 2) ->
        case fun.(temporary_dir, final_dir) do
          :ok -> :ok
          {:error, _} = error -> error
          _ -> {:error, :invalid_publish_hook_result}
        end

      nil ->
        :ok

      _ ->
        {:error, :invalid_publish_hook}
    end
  end

  defp cleanup_failed_publish(temporary_dir, {:error, reason}),
    do: cleanup_and_error(temporary_dir, reason)

  defp cleanup_failed_publish(temporary_dir, other), do: cleanup_and_error(temporary_dir, other)

  defp cleanup_and_error(path, reason) do
    _ = File.rm_rf(path)
    {:error, reason}
  end

  defp resolve_ambiguity(%{"title" => title, "summary" => summary} = record, _opts)
       when is_binary(title) and title != "" and is_binary(summary) and summary != "" do
    {:ok, record}
  end

  defp resolve_ambiguity(record, opts) do
    case Keyword.get(opts, :llm) do
      fun when is_function(fun, 1) ->
        apply_candidate(record, fun.(record), "resolver")

      {module, module_opts} when is_atom(module) and is_list(module_opts) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :resolve, 2) do
          apply_candidate(record, module.resolve(record, module_opts), "resolver")
        else
          {:error, :invalid_llm_resolver}
        end

      nil ->
        run_configured_provider(record, opts)

      _ ->
        {:error, :invalid_llm_resolver}
    end
  end

  defp run_configured_provider(record, opts) do
    case configured_provider(opts) do
      nil ->
        {:error, :llm_required_for_ambiguous_input}

      provider ->
        run_opts = [
          loop: Alto.chat_loop(),
          provider: provider,
          approval: Alto.Approvals.DenyAll,
          tools: [],
          max_steps: 1,
          max_effects: 2,
          provider_timeout: Keyword.get(opts, :provider_timeout, 30_000)
        ]

        case Alto.run(extraction_prompt(record), run_opts) do
          {:ok, result} when is_map(result) ->
            case JSON.decode(Map.get(result, :output, "")) do
              {:ok, candidate} -> apply_candidate(record, candidate, "alto")
              _ -> {:error, :invalid_llm_result}
            end

          {:error, reason, _result} ->
            {:error, {:llm_failed, reason}}

          _ ->
            {:error, :invalid_llm_result}
        end
    end
  end

  defp configured_provider(opts) do
    case Keyword.get(opts, :provider) do
      {module, provider_opts} = provider when is_atom(module) and is_list(provider_opts) ->
        provider

      module when is_atom(module) and not is_nil(module) ->
        {module, Keyword.get(opts, :provider_options, [])}

      nil ->
        case Keyword.get(opts, :config) do
          %Alto.Config{} = config ->
            config_opts = Alto.Config.run_options(config)

            case Keyword.get(config_opts, :provider) do
              nil ->
                nil

              {module, provider_opts} = provider
              when is_atom(module) and is_list(provider_opts) ->
                provider

              provider when is_atom(provider) ->
                {provider, Keyword.get(config_opts, :provider_options, [])}
            end

          _ ->
            nil
        end

      provider ->
        provider
    end
  end

  defp extraction_prompt(record) do
    source = JSON.encode!(%{"source_text" => record["source_text"]})

    """
    Extract the missing document metadata from this source. Return JSON only,
    with exactly these optional fields: title (string), summary (string), and
    fields (object whose values are strings). Do not return identity; it is
    assigned from the source by the caller. Keep every string under #{@max_string_bytes} bytes.
    Source: #{source}
    """
  end

  defp apply_candidate(_record, {:error, reason}, _kind), do: {:error, reason}

  defp apply_candidate(record, {:ok, candidate}, kind),
    do: apply_candidate(record, candidate, kind)

  defp apply_candidate(_record, other, _kind) when not is_map(other),
    do: {:error, :invalid_llm_result}

  defp apply_candidate(record, candidate, kind) do
    merged =
      record
      |> Map.merge(Map.take(candidate, ["title", "summary", "fields"]))
      |> Map.put("identity", record["identity"])
      |> Map.put("provenance", %{"kind" => kind})

    case validate(merged) do
      :ok -> {:ok, merged}
      {:error, :invalid_document_schema} -> {:error, :invalid_llm_schema}
    end
  end

  defp maybe_persist_candidate(record, opts) do
    case Keyword.get(opts, :state_dir) do
      dir when is_binary(dir) -> persist_candidate(record, dir)
      _ -> :ok
    end
  end

  defp maybe_persist(record, opts) do
    case Keyword.get(opts, :state_dir) do
      dir when is_binary(dir) -> persist_candidate(record, dir)
      _ -> :ok
    end
  end

  defp resume_candidate(record, opts) do
    case Keyword.get(opts, :state_dir) do
      dir when is_binary(dir) ->
        case load_candidate(record["identity"], dir) do
          {:ok, persisted} ->
            if persisted["source_text"] == record["source_text"], do: persisted, else: record

          _ ->
            record
        end

      _ ->
        record
    end
  end

  defp validate_candidate(record) do
    with :ok <- valid_identity(Map.get(record, "identity")),
         :ok <- valid_source(Map.get(record, "source_text")),
         :ok <- valid_fields(Map.get(record, "fields")) do
      :ok
    else
      _ -> {:error, :invalid_document_schema}
    end
  end

  defp valid_correction(correction) do
    if Enum.all?(Map.keys(correction), &(&1 in ["title", "summary", "fields"])),
      do: :ok,
      else: {:error, :invalid_correction}
  end

  defp valid_identity(id) when is_binary(id) and byte_size(id) == @max_identity_bytes do
    if Regex.match?(~r/\A[0-9a-f]{24}\z/, id), do: :ok, else: {:error, :invalid_identity}
  end

  defp valid_identity(_), do: {:error, :invalid_identity}

  defp valid_string(value, _name, allow_empty) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @max_string_bytes and
         (allow_empty or value != ""),
       do: :ok,
       else: {:error, :invalid_string}
  end

  defp valid_string(_value, _name, _allow_empty), do: {:error, :invalid_string}

  defp valid_source(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @max_input_bytes,
      do: :ok,
      else: {:error, :invalid_string}
  end

  defp valid_source(_value), do: {:error, :invalid_string}

  defp valid_fields(fields) when is_map(fields) and map_size(fields) <= @max_field_count do
    if Enum.all?(fields, fn {key, value} ->
         is_binary(key) and String.valid?(key) and byte_size(key) <= @max_field_key_bytes and
           Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, key) and is_binary(value) and
           String.valid?(value) and byte_size(value) <= @max_string_bytes
       end),
       do: :ok,
       else: {:error, :invalid_fields}
  end

  defp valid_fields(_), do: {:error, :invalid_fields}
  defp valid_provenance(nil), do: :ok
  defp valid_provenance(value) when is_map(value), do: :ok
  defp valid_provenance(_), do: {:error, :invalid_provenance}

  defp deterministic(text) do
    identity = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 24)

    title =
      Regex.run(~r/(?m)^#\s+(.+?)\s*$/, text, capture: :all_but_first)
      |> List.wrap()
      |> List.first()

    summary =
      Regex.run(~r/(?m)^summary:\s*(.+?)\s*$/i, text, capture: :all_but_first)
      |> List.wrap()
      |> List.first()

    fields =
      Regex.scan(~r/(?m)^[-*]\s+([A-Za-z][A-Za-z0-9_-]{0,63}):\s*(.+?)\s*$/, text,
        capture: :all_but_first
      )
      |> Map.new(fn [key, value] -> {String.downcase(key), value} end)

    %{
      "identity" => identity,
      "title" => title,
      "summary" => summary,
      "fields" => fields,
      "source_text" => text
    }
  end

  defp candidate_path(dir, identity), do: Path.join(dir, ".document-#{identity}.candidate.json")

  defp write_private_json(path, record) do
    Alto.Tools.AtomicWrite.write(path, JSON.encode!(record) <> "\n", 0o600)
  end

  defp bounded_read(path, max) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result =
          case IO.binread(io, max + 1) do
            {:error, reason} -> {:error, reason}
            :eof -> {:ok, <<>>}
            body when byte_size(body) > max -> {:error, :candidate_too_large}
            body -> {:ok, body}
          end

        _ = File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_existing(dir, record) do
    prefix = "document-#{record["identity"]}-v"

    dir
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.sort()
    |> Enum.find_value(:missing, fn name ->
      path = Path.join([dir, name, "document.json"])

      with {:ok, body} <- bounded_read(path, @max_candidate_file_bytes),
           {:ok, existing} <- JSON.decode(body),
           :ok <- validate(existing),
           true <- fingerprint(existing) == fingerprint(record) do
        version = version_from_name(name, record["identity"])

        case File.exists?(Path.join([dir, name, "document.csv"])) do
          true ->
            {:ok,
             %{
               version: version,
               json: path,
               csv: Path.join([dir, name, "document.csv"]),
               duplicate?: true
             }}

          false ->
            {:error, :incomplete_artifact}
        end
      else
        _ -> nil
      end
    end)
  end

  defp fingerprint(record),
    do:
      record
      |> Map.take(["identity", "title", "summary", "fields", "source_text"])
      |> JSON.encode!()

  defp next_version(dir, identity) do
    dir
    |> File.ls!()
    |> Enum.map(&version_from_name(&1, identity))
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp version_from_name(name, identity) do
    case Regex.run(~r/\Adocument-#{Regex.escape(identity)}-v(\d+)\z/, name,
           capture: :all_but_first
         ) do
      [version] -> String.to_integer(version)
      _ -> nil
    end
  end

  defp unique_suffix, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp csv(record, version) do
    header = "schema_version,version,identity,title,summary,fields\n"

    escaped_fields =
      record["fields"]
      |> Map.new(fn {key, value} -> {key, formula_escape(value)} end)
      |> JSON.encode!()

    row =
      [
        @schema_version,
        version,
        record["identity"],
        record["title"],
        record["summary"],
        escaped_fields
      ]
      |> Enum.map(&csv_cell/1)
      |> Enum.join(",")

    header <> row <> "\n"
  end

  defp formula_escape(value) when is_binary(value) do
    if String.starts_with?(value, ["=", "+", "-", "@"]), do: "'" <> value, else: value
  end

  defp formula_escape(value), do: value

  defp csv_cell(value) do
    value = value |> to_string() |> formula_escape()
    "\"" <> String.replace(value, "\"", "\"\"") <> "\""
  end
end
