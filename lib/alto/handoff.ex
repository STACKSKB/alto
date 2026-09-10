defmodule Alto.Handoff do
  @moduledoc """
  Structured, durable context rollover for long-running coding tasks.

  A handoff is deliberately not a prose summary. It separates the design
  constraints, concrete code pointers, current state, and one next action so a
  later run can inspect or replace each part independently. Artifacts live with
  the session state rather than in the repository: context management must not
  dirty the user's working tree.
  """

  alias Alto.Session
  alias Alto.Tools.AtomicWrite

  @files %{
    design: "the design contract",
    pointers: "POINTERS.md",
    handoff: "HANDOFF.md",
    next_step: "NEXT_STEP.md"
  }

  @type artifact :: %{
          design: String.t(),
          pointers: String.t(),
          handoff: String.t(),
          next_step: String.t()
        }

  @doc "Build the bounded provider prompt used to produce a structured handoff."
  @spec prompt(String.t(), pos_integer()) :: String.t()
  def prompt(transcript, max_bytes) when is_binary(transcript) and is_integer(max_bytes) do
    """
    Prepare a context handoff for another coding-agent run. This is not a chat
    summary. Return exactly one JSON object with four string fields:

    - design: settled goals, invariants, architecture, and rejected alternatives
    - pointers: exact files, modules, symbols, commands, and evidence worth reopening
    - handoff: completed work, current state, failures, risks, and unresolved seams
    - next_step: one concrete next action, including its verification condition

    Do not use markdown fences or tool calls. Do not invent completed work. Keep
    the entire JSON response under #{max_bytes} bytes. Prefer exact pointers over
    narrative, and preserve explicit user decisions.

    Transcript:
    #{transcript}
    """
  end

  @doc "Decode and validate a provider-produced handoff JSON object."
  @spec decode(String.t(), pos_integer()) :: {:ok, artifact()} | {:error, term()}
  def decode(payload, max_bytes) when is_binary(payload) and is_integer(max_bytes) do
    cond do
      payload == "" ->
        {:error, :handoff_empty}

      byte_size(payload) > max_bytes ->
        {:error, {:handoff_too_large, byte_size(payload), max_bytes}}

      not String.valid?(payload) ->
        {:error, :handoff_not_utf8}

      true ->
        with {:ok, decoded} <- decode_json(payload),
             {:ok, artifact} <- validate_fields(decoded),
             :ok <- validate_rendered_size(artifact, max_bytes) do
          {:ok, artifact}
        end
    end
  end

  @doc "Render the structured handoff as the compact model-context replacement."
  @spec render(artifact()) :: String.t()
  def render(artifact) do
    """
    # Design
    #{artifact.design}

    # Pointers
    #{artifact.pointers}

    # Handoff
    #{artifact.handoff}

    # Next step
    #{artifact.next_step}
    """
    |> String.trim()
  end

  @doc "Atomically publish all handoff files under the session state directory."
  @spec persist(String.t(), String.t(), artifact(), keyword()) ::
          {:ok, %{directory: Path.t(), files: %{atom() => Path.t()}}} | {:error, term()}
  def persist(session_id, run_id, artifact, opts \\ []) do
    with :ok <- Session.validate_id(session_id),
         :ok <- Session.validate_id(run_id),
         {:ok, artifact} <- validate_fields(artifact) do
      root =
        opts
        |> Keyword.get_lazy(:artifact_dir, fn ->
          Path.join([Session.dir(opts), "handoffs"])
        end)
        |> Path.expand()

      final_dir = Path.join([root, session_id, run_id])
      publish(final_dir, artifact)
    end
  end

  defp decode_json(payload) do
    case JSON.decode(payload) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, {:handoff_invalid_json, inspect(error)}}
    end
  end

  defp validate_fields(fields) when is_map(fields) do
    Enum.reduce_while(@files, {:ok, %{}}, fn {key, _filename}, {:ok, artifact} ->
      value = Map.get(fields, key, Map.get(fields, Atom.to_string(key)))

      if is_binary(value) and value != "" and String.valid?(value) do
        {:cont, {:ok, Map.put(artifact, key, value)}}
      else
        {:halt, {:error, {:invalid_handoff_field, key}}}
      end
    end)
  end

  defp validate_fields(_other), do: {:error, :handoff_must_be_object}

  defp validate_rendered_size(artifact, max_bytes) do
    size = byte_size(render(artifact))
    if size <= max_bytes, do: :ok, else: {:error, {:handoff_render_too_large, size, max_bytes}}
  end

  defp publish(final_dir, artifact) do
    parent = Path.dirname(final_dir)
    temp_dir = final_dir <> ".tmp-" <> random_suffix()

    with :ok <- mkdir(parent),
         :ok <- mkdir(temp_dir),
         :ok <- write_artifacts(temp_dir, artifact),
         :ok <- rename_publish(temp_dir, final_dir) do
      {:ok,
       %{
         directory: final_dir,
         files: Map.new(@files, fn {key, filename} -> {key, Path.join(final_dir, filename)} end)
       }}
    else
      {:error, reason} ->
        File.rm_rf(temp_dir)
        {:error, {:handoff_write_failed, reason}}
    end
  end

  defp write_artifacts(directory, artifact) do
    Enum.reduce_while(@files, :ok, fn {key, filename}, :ok ->
      content = Map.fetch!(artifact, key) <> "\n"

      case AtomicWrite.write(Path.join(directory, filename), content, 0o600) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rename_publish(temp_dir, final_dir) do
    case File.rename(temp_dir, final_dir) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :handoff_already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mkdir(path) do
    case Alto.Storage.ensure_private_dir(path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp random_suffix do
    Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  end
end
