defmodule RepositoryMaintenance.Workflow do
  @moduledoc "Durable CI failure intake, isolated repair, review manifest, and explicit apply."

  alias Alto.Command
  alias Alto.Tool.Context
  alias Alto.Tools.AtomicWrite
  alias Alto.Tools.Git

  @max_report_bytes 64_000
  @max_patch_bytes 1_000_000
  @max_manifest_bytes 128_000

  @doc "Read a bounded binary file before callers decode or process it."
  def read_bounded(path, max) when is_binary(path) and is_integer(max) and max >= 0 do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result =
          case IO.binread(io, max + 1) do
            {:error, reason} -> {:error, reason}
            :eof -> {:ok, <<>>}
            body when byte_size(body) > max -> {:error, :file_too_large}
            body -> {:ok, body}
          end

        _ = File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  def validate_report(
        %{"source" => source, "delivery_id" => id, "commit" => commit, "failure" => failure} =
          report
      )
      when is_binary(source) and source != "" and is_binary(id) and id != "" and
             is_binary(commit) and is_binary(failure) and failure != "" do
    if Regex.match?(~r/\A[0-9a-fA-F]{7,64}\z/, commit) and byte_size(id) <= 200 and
         Map.get(report, "kind") in ["ci_failure", "local_failure"],
       do: :ok,
       else: {:error, :invalid_report}
  end

  def validate_report(_report), do: {:error, :invalid_report}

  def admit(queue, report) do
    with :ok <- validate_report(report),
         body <- JSON.encode!(report),
         true <- byte_size(body) <= @max_report_bytes or {:error, :report_too_large} do
      Alto.Queue.admit(queue, report["source"] <> ":" <> report["delivery_id"], %{
        "body" => body,
        "report" => report
      })
    end
  end

  @doc "Return the private, source keyed state directory used by the profile."
  def state_dir(repo, opts \\ []) do
    Keyword.get(opts, :state_dir) ||
      Path.join(System.tmp_dir!(), "alto-maintenance-" <> hash(Path.expand(repo)))
  end

  @doc "Claim, diagnose in a detached worktree, test, and write a review manifest."
  def process(queue, repo, opts \\ []) do
    with {:ok, state} <- prepare_state(repo, opts) do
      process_claim(queue, repo, Keyword.put(opts, :state_dir, state))
    end
  end

  @doc "Validate and create the private state tree before any queue work starts."
  def prepare_state(repo, opts \\ []) do
    with {:ok, state} <- private_state_dir(repo, opts),
         :ok <- Alto.Storage.ensure_private_dir(state, owned: true),
         :ok <- Alto.Storage.ensure_private_dir(Path.join(state, "worktrees"), owned: true),
         :ok <- Alto.Storage.ensure_private_dir(Path.join(state, "artifacts"), owned: true),
         :ok <- Alto.Storage.ensure_private_dir(Path.join(state, "errors"), owned: true) do
      {:ok, state}
    end
  end

  defp process_claim(queue, repo, opts) do
    case Alto.Queue.claim(queue, 1, "repository-maintenance") do
      {:ok, [record]} ->
        case checkout(repo, record.payload["report"]["commit"], opts) do
          {:ok, checkout} ->
            result =
              with diagnosis <- diagnose(checkout, record.payload["report"], opts),
                   {:ok, manifest} <- build_manifest(repo, checkout, diagnosis, opts) do
                {:ok, manifest}
              end

            case result do
              {:ok, manifest} ->
                case Alto.Queue.ack(queue, record.claim_id) do
                  :ok ->
                    {:ok, manifest}

                  {:error, reason} ->
                    persist_error(opts, record, {:ack_uncertain, reason, manifest})
                    {:unknown, {:ack_uncertain, reason, manifest}}

                  other ->
                    persist_error(opts, record, {:ack_uncertain, other, manifest})
                    {:unknown, {:ack_uncertain, other, manifest}}
                end

              {:error, reason} ->
                persist_error(opts, record, reason)
                {:error, reason}
            end

          {:error, reason} ->
            wrapped = {:checkout_failed, reason}
            persist_error(opts, record, wrapped)
            {:error, wrapped}
        end

      {:ok, []} ->
        {:error, :no_pending_reports}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Apply only a reviewed manifest whose hash and base still match."
  def apply_reviewed(repo, manifest_path, expected_hash) do
    with :ok <- safe_artifact_path(repo, manifest_path),
         {:ok, manifest_json} <- read_bounded(manifest_path, @max_manifest_bytes),
         true <- hash(manifest_json) == expected_hash or {:error, :manifest_hash_mismatch},
         {:ok, manifest} <- JSON.decode(manifest_json),
         :ok <- verify_manifest(manifest),
         :ok <- safe_artifact_path(repo, manifest["patch_path"]),
         {:ok, patch} <- read_bounded(manifest["patch_path"], @max_patch_bytes),
         true <- byte_size(patch) <= @max_patch_bytes or {:error, :patch_too_large},
         true <- hash(patch) == manifest["patch_sha256"] or {:error, :patch_hash_mismatch},
         {:ok, head} <- git(repo, ["rev-parse", "HEAD"]),
         true <- String.trim(head) == manifest["base_commit"] or {:error, :stale_base},
         {:ok, tree} <- git(repo, ["rev-parse", "HEAD^{tree}"]),
         true <- String.trim(tree) == manifest["base_tree"] or {:error, :stale_tree},
         {:ok, status} <- git(repo, ["status", "--porcelain"]),
         true <- String.trim(status) == "" or {:error, :stale_tree} do
      apply_patch(repo, manifest, patch, manifest_path)
    end
  end

  defp checkout(repo, commit, opts) do
    state = Keyword.get(opts, :state_dir, Path.join(System.tmp_dir!(), "alto-maintenance-state"))

    dir =
      Path.join(
        Path.join(state, "worktrees"),
        random_id()
      )

    with :ok <- File.mkdir_p(Path.dirname(dir)),
         {:ok, _} <- git(repo, ["rev-parse", "--verify", commit <> "^{commit}"], read_only: true),
         {:ok, _} <- git(repo, ["worktree", "add", "--detach", dir, commit]) do
      {:ok, dir}
    end
  end

  defp diagnose(checkout, report, opts) do
    case Keyword.get(opts, :diagnoser) do
      callback when is_function(callback, 2) ->
        callback.(checkout, report)

      _ ->
        with {:ok, provider} <- provider_options(opts) do
          Alto.run(report["failure"],
            cwd: checkout,
            provider: {Alto.Providers.OpenAICompatible, provider},
            tools: [
              Alto.Tools.ReadFile,
              Alto.Tools.SearchFiles,
              Alto.Tools.EditFile,
              Alto.Tools.WriteFile
            ],
            approval: Alto.Approvals.AllowAll,
            max_steps: Keyword.get(opts, :max_steps, 8)
          )
        end
    end
  end

  defp build_manifest(_repo, checkout, {:ok, _run}, opts) do
    with {:ok, test_output} <- run_tests(checkout, opts),
         {:ok, _} <- git(checkout, ["add", "--all"]),
         {:ok, _} <-
           git(checkout, ["diff", "--cached", "--check", "--no-ext-diff", "HEAD"],
             read_only: true
           ),
         {:ok, base} <- git(checkout, ["rev-parse", "HEAD"], read_only: true),
         {:ok, base_tree} <- git(checkout, ["rev-parse", "HEAD^{tree}"], read_only: true),
         {:ok, diff} <-
           git(checkout, ["diff", "--cached", "--binary", "--no-ext-diff", "HEAD"],
             read_only: true
           ),
         true <-
           byte_size(diff) <= Keyword.get(opts, :max_patch_bytes, @max_patch_bytes) or
             {:error, :patch_too_large} do
      state =
        Keyword.get(opts, :state_dir, Path.join(System.tmp_dir!(), "alto-maintenance-state"))

      dir = Path.join(state, "artifacts")
      id = hash(diff <> String.trim(base))
      bundle_dir = Path.join(dir, id)
      patch_path = Path.join(bundle_dir, "patch.diff")
      test_path = Path.join(bundle_dir, "tests.txt")
      manifest_path = Path.join(bundle_dir, "manifest.json")

      manifest = %{
        "version" => 1,
        "patch_id" => id,
        "patch_sha256" => hash(diff),
        "base_commit" => String.trim(base),
        "base_tree" => String.trim(base_tree),
        "patch_path" => patch_path,
        "test_output_path" => test_path,
        "reviewed" => false,
        "checkout" => checkout
      }

      publish_artifacts(
        bundle_dir,
        patch_path,
        test_path,
        manifest_path,
        diff,
        test_output,
        manifest
      )
    end
  end

  defp build_manifest(_repo, _checkout, {:error, reason}, _opts),
    do: {:error, {:diagnosis_failed, reason}}

  defp build_manifest(_repo, _checkout, {:error, reason, _result}, _opts),
    do: {:error, {:diagnosis_failed, reason}}

  defp build_manifest(_repo, _checkout, other, _opts),
    do: {:error, {:invalid_diagnosis_result, other}}

  defp run_tests(checkout, opts) do
    case Keyword.get(opts, :tests, ["mix", "test"]) do
      [program | args] when is_binary(program) and is_list(args) ->
        if Enum.all?(args, &is_binary/1) do
          Command.run(
            %{
              "program" => program,
              "args" => args,
              "timeout_ms" => Keyword.get(opts, :test_timeout_ms, 120_000),
              "max_output_bytes" => 64_000
            },
            %Context{session_id: "maintenance-tests", cwd: checkout}
          )
          |> normalize_test_result()
        else
          {:error, :invalid_test_command}
        end

      _ ->
        {:error, :invalid_test_command}
    end
  end

  defp normalize_test_result({:ok, %{exit_status: 0, output: output}}), do: {:ok, output}

  defp normalize_test_result({:ok, %{exit_status: status, output: output}}),
    do: {:error, {:tests_failed, status, output}}

  defp normalize_test_result({:ok, result}), do: {:error, {:tests_uncertain, result}}
  defp normalize_test_result({:error, reason}), do: {:error, {:tests_uncertain, reason}}

  defp verify_manifest(%{
         "patch_id" => id,
         "patch_sha256" => sha,
         "base_commit" => base,
         "base_tree" => tree,
         "reviewed" => true,
         "patch_path" => path
       })
       when is_binary(id) and is_binary(sha) and is_binary(base) and is_binary(tree) and
              is_binary(path) do
    with true <- valid_hex?(id, 64),
         true <- valid_hex?(sha, 64),
         true <- valid_hex?(base, 7..64),
         true <- valid_hex?(tree, 40),
         {:ok, patch} <- read_bounded(path, @max_patch_bytes),
         true <- hash(patch) == sha or {:error, :patch_hash_mismatch},
         do: :ok
  end

  defp verify_manifest(%{"reviewed" => false}), do: {:error, :manifest_not_reviewed}

  defp verify_manifest(_), do: {:error, :invalid_manifest}

  defp private_state_dir(repo, opts) do
    state = state_dir(repo, opts)
    repo = Path.expand(repo)
    state = Path.expand(state)

    with :ok <- reject_symlink_components(repo),
         :ok <- reject_symlink_components(state) do
      if path_within?(state, repo),
        do: {:error, :state_dir_inside_repository},
        else: {:ok, state}
    else
      {:error, :state_dir_symlink} -> {:error, :state_dir_symlink}
      {:error, _reason} -> {:error, :invalid_state_dir}
    end
  end

  defp reject_symlink_components(path) do
    parts = Path.expand(path) |> Path.split()
    {prefix, parts} = if hd(parts) == "/", do: {"/", tl(parts)}, else: {"", parts}

    parts
    |> Enum.reduce_while({:ok, prefix}, fn component, {:ok, prefix} ->
      current = Path.join(prefix, component)

      case File.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :state_dir_symlink}}
        {:ok, _stat} -> {:cont, {:ok, current}}
        {:error, :enoent} -> {:cont, {:ok, current}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      error -> error
    end
  end

  defp safe_artifact_path(repo, path) when is_binary(path) do
    repo = Path.expand(repo)
    path = Path.expand(path)

    with :ok <- reject_symlink_components(repo),
         :ok <- reject_symlink_components(path) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:error, :unsafe_artifact_path}

        {:ok, _stat} ->
          if path_within?(path, repo), do: {:error, :unsafe_artifact_path}, else: :ok

        {:error, _reason} ->
          {:error, :unsafe_artifact_path}
      end
    else
      _ -> {:error, :unsafe_artifact_path}
    end
  end

  defp safe_artifact_path(_repo, _path), do: {:error, :unsafe_artifact_path}

  defp path_within?(path, parent) do
    path == parent or String.starts_with?(path, parent <> "/")
  end

  defp freeze_patch(manifest, patch) do
    dir = Path.dirname(manifest["patch_path"])
    path = Path.join(dir, ".apply-" <> random_id() <> ".patch")

    case AtomicWrite.write(path, patch, 0o600) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:patch_freeze_failed, reason}}
    end
  end

  defp apply_patch(repo, manifest, patch, manifest_path) do
    case freeze_patch(manifest, patch) do
      {:ok, frozen} ->
        case record_apply(manifest_path, manifest, :started) do
          :ok ->
            result = git(repo, ["apply", "--index", "--whitespace=error-all", frozen])
            _ = File.rm(frozen)

            case result do
              {:ok, _} ->
                case record_apply(manifest_path, manifest, :applied) do
                  :ok -> {:ok, manifest}
                  {:error, reason} -> {:unknown, {:apply_evidence_uncertain, reason}}
                end

              {:error, reason} when reason in [:git_timeout, :git_output_limit] ->
                _ = record_apply(manifest_path, manifest, {:unknown, reason})
                {:unknown, {:apply_uncertain, reason}}

              {:error, reason} ->
                _ = record_apply(manifest_path, manifest, {:failed, reason})
                {:error, {:apply_failed, reason}}
            end

          {:error, reason} ->
            _ = File.rm(frozen)
            {:error, {:apply_evidence_failed, reason}}
        end

      {:error, reason} ->
        record_apply(manifest_path, manifest, {:unknown, reason})
        {:unknown, {:apply_uncertain, reason}}
    end
  end

  defp record_apply(manifest_path, manifest, status) do
    path = Path.join(Path.dirname(manifest_path), manifest["patch_id"] <> ".apply.json")

    content =
      JSON.encode!(%{"patch_id" => manifest["patch_id"], "status" => inspect(status)}) <> "\n"

    AtomicWrite.write(path, content, 0o600)
  end

  defp publish_artifacts(dir, patch_path, test_path, manifest_path, diff, test_output, manifest) do
    json = JSON.encode!(manifest) <> "\n"
    tmp = dir <> ".tmp-" <> random_id()

    result =
      with :ok <- Alto.Storage.ensure_private_dir(Path.dirname(dir), owned: true),
           :ok <- Alto.Storage.ensure_private_dir(tmp, owned: true),
           :ok <- AtomicWrite.write(Path.join(tmp, Path.basename(patch_path)), diff, 0o600),
           :ok <- AtomicWrite.write(Path.join(tmp, Path.basename(test_path)), test_output, 0o600),
           :ok <- AtomicWrite.write(Path.join(tmp, Path.basename(manifest_path)), json, 0o600),
           :ok <- File.rename(tmp, dir) do
        {:ok, Map.put(manifest, "manifest_path", manifest_path)}
      end

    case result do
      {:ok, _} = ok ->
        ok

      {:error, :eexist} ->
        _ = File.rm_rf(tmp)

        with {:ok, ^diff} <- read_bounded(patch_path, @max_patch_bytes),
             {:ok, _existing_test_output} <- read_bounded(test_path, 64_000),
             {:ok, existing_json} <- read_bounded(manifest_path, @max_manifest_bytes),
             {:ok, existing} <- JSON.decode(existing_json),
             true <- same_patch_manifest?(existing, manifest) do
          {:ok, Map.put(existing, "manifest_path", manifest_path)}
        else
          _ -> {:error, :artifact_collision}
        end

      {:error, reason} ->
        _ = File.rm_rf(tmp)
        {:error, {:artifact_publish_failed, reason}}
    end
  end

  defp same_patch_manifest?(existing, expected) when is_map(existing) do
    Map.take(existing, ["version", "patch_id", "patch_sha256", "base_commit", "base_tree"]) ==
      Map.take(expected, ["version", "patch_id", "patch_sha256", "base_commit", "base_tree"])
  end

  defp same_patch_manifest?(_existing, _expected), do: false

  defp valid_hex?(value, size) when is_binary(value) and is_integer(size) do
    byte_size(value) == size and Regex.match?(~r/\A[0-9a-f]+\z/, value)
  end

  defp valid_hex?(value, %Range{first: min, last: max}) when is_binary(value) do
    byte_size(value) in min..max and Regex.match?(~r/\A[0-9a-fA-F]+\z/, value)
  end

  defp valid_hex?(_value, _size), do: false

  defp provider_options(opts) do
    endpoint = Keyword.get(opts, :endpoint) || System.get_env("ALTO_PROVIDER_ENDPOINT")
    model = Keyword.get(opts, :model) || System.get_env("ALTO_MODEL")
    key = Keyword.get(opts, :api_key) || System.get_env("ALTO_API_KEY")

    if is_binary(endpoint) and endpoint != "" and is_binary(model) and model != "",
      do: {:ok, [endpoint: endpoint, model: model, api_key: key]},
      else: {:error, :provider_required_for_maintenance}
  end

  defp persist_error(opts, record, reason) do
    dir =
      Path.join(
        Keyword.get(opts, :state_dir, Path.join(System.tmp_dir!(), "alto-maintenance-state")),
        "errors"
      )

    with :ok <- Alto.Storage.ensure_private_dir(dir, owned: true) do
      AtomicWrite.write(
        Path.join(dir, to_string(record.id) <> ".json"),
        JSON.encode!(%{"record_id" => record.id, "error" => inspect(reason)}) <> "\n",
        0o600
      )
    end
  end

  defp git(repo, args, opts \\ []) do
    case Git.run(
           args,
           %Context{session_id: "maintenance-git", cwd: repo},
           Keyword.merge([max_output_bytes: 64_000], opts)
         ) do
      {:ok, result} -> {:ok, Map.get(result, :output, "")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
