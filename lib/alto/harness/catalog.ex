defmodule Alto.Harness.Catalog do
  @moduledoc """
  A small, database-free catalog of projects and coding tasks.

  The catalog is navigation state, not execution truth. Alto sessions remain
  the durable source for transcripts and outcomes. Every mutation rereads the
  latest JSON document under an OS advisory file lock and publishes it with
  an atomic rename, so independent front ends cannot silently overwrite each
  other's project/task additions.
  """

  alias Alto.Session
  alias Alto.Tools.AtomicWrite

  @version 1
  @statuses ~w(active waiting completed failed archived)
  @max_projects 500
  @max_tasks 10_000
  @max_catalog_bytes 32_000_000
  @max_title_bytes 2_000
  @max_state_field_bytes 32_000

  @type path :: Path.t()
  @type project :: map()
  @type task :: map()

  @doc "Default catalog path beside, but separate from, session logs."
  @spec default_path(keyword()) :: path()
  def default_path(opts \\ []) do
    Path.join(Path.dirname(Session.dir(opts)), "harness.json")
  end

  @doc "Read the catalog, returning an empty value if it has not been created."
  @spec read(keyword()) :: {:ok, map()} | {:error, term()}
  def read(opts \\ []) do
    path = Keyword.get(opts, :path, default_path(opts)) |> Path.expand()

    case bounded_read(path) do
      {:ok, encoded} ->
        decode(encoded, path)

      {:error, {:too_large, size}} ->
        {:error, {:catalog_too_large, size, @max_catalog_bytes}}

      {:error, :enoent} ->
        {:ok, empty()}

      {:error, reason} ->
        {:error, {:catalog_read_failed, reason}}
    end
  end

  defp bounded_read(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result =
          case IO.binread(io, @max_catalog_bytes + 1) do
            {:error, reason} ->
              {:error, reason}

            :eof ->
              {:ok, <<>>}

            content when byte_size(content) > @max_catalog_bytes ->
              {:error, {:too_large, @max_catalog_bytes + 1}}

            content ->
              {:ok, content}
          end

        File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Register or touch a project by canonical root."
  @spec register_project(Path.t(), keyword()) :: {:ok, project()} | {:error, term()}
  def register_project(root, opts \\ []) when is_binary(root) do
    expanded = Path.expand(root)
    name = Keyword.get(opts, :name, Path.basename(expanded))

    cond do
      not File.dir?(expanded) ->
        {:error, {:project_not_directory, expanded}}

      not valid_text?(name) ->
        {:error, {:invalid_project_name, name}}

      true ->
        transact(opts, fn catalog ->
          now = now_ms()

          case Enum.find(catalog["projects"], &(&1["root"] == expanded)) do
            nil ->
              if length(catalog["projects"]) >= @max_projects do
                {:error, :project_capacity}
              else
                project = %{
                  "id" => id("project"),
                  "name" => bounded_string(name, @max_title_bytes),
                  "root" => expanded,
                  "created_at_ms" => now,
                  "last_opened_at_ms" => now
                }

                {:ok, Map.update!(catalog, "projects", &(&1 ++ [project])), project}
              end

            project ->
              updated = Map.put(project, "last_opened_at_ms", now)

              catalog =
                Map.update!(catalog, "projects", fn projects ->
                  Enum.map(projects, &if(&1["id"] == project["id"], do: updated, else: &1))
                end)

              {:ok, catalog, updated}
          end
        end)
    end
  end

  @doc "Create a task under an existing project."
  @spec create_task(String.t(), String.t(), keyword()) :: {:ok, task()} | {:error, term()}
  def create_task(project_id, title, opts \\ [])
      when is_binary(project_id) and is_binary(title) and title != "" do
    backend = Keyword.get(opts, :backend, "alto")

    if String.valid?(title) and valid_backend?(backend) do
      transact(opts, fn catalog ->
        cond do
          not Enum.any?(catalog["projects"], &(&1["id"] == project_id)) ->
            {:error, {:unknown_project, project_id}}

          length(catalog["tasks"]) >= @max_tasks ->
            {:error, :task_capacity}

          true ->
            now = now_ms()

            task = %{
              "id" => id("task"),
              "project_id" => project_id,
              "title" => bounded_string(title, @max_title_bytes),
              "status" => "active",
              "backend" => backend,
              "session_id" => Keyword.get(opts, :session_id),
              "backend_thread_id" => Keyword.get(opts, :backend_thread_id),
              "next_step" => nil,
              "handoff_directory" => nil,
              "created_at_ms" => now,
              "updated_at_ms" => now
            }

            {:ok, Map.update!(catalog, "tasks", &(&1 ++ [task])), task}
        end
      end)
    else
      if String.valid?(title),
        do: {:error, :invalid_task_backend},
        else: {:error, :invalid_task_title}
    end
  end

  @doc "Update the navigation fields owned by the harness for one task."
  @spec update_task(String.t(), map() | keyword(), keyword()) ::
          {:ok, task()} | {:error, term()}
  def update_task(task_id, changes, opts \\ []) when is_binary(task_id) do
    changes = if is_list(changes), do: Map.new(changes), else: changes

    with {:ok, changes} <- validate_changes(changes) do
      transact(opts, fn catalog ->
        case Enum.find(catalog["tasks"], &(&1["id"] == task_id)) do
          nil ->
            {:error, {:unknown_task, task_id}}

          task ->
            updated = task |> Map.merge(changes) |> Map.put("updated_at_ms", now_ms())

            catalog =
              Map.update!(catalog, "tasks", fn tasks ->
                Enum.map(tasks, &if(&1["id"] == task_id, do: updated, else: &1))
              end)

            {:ok, catalog, updated}
        end
      end)
    end
  end

  @doc "List projects by recency."
  @spec projects(keyword()) :: {:ok, [project()]} | {:error, term()}
  def projects(opts \\ []) do
    with {:ok, catalog} <- read(opts) do
      {:ok, Enum.sort_by(catalog["projects"], & &1["last_opened_at_ms"], :desc)}
    end
  end

  @doc "List one project's tasks by recency, optionally including archived tasks."
  @spec tasks(String.t(), keyword()) :: {:ok, [task()]} | {:error, term()}
  def tasks(project_id, opts \\ []) when is_binary(project_id) do
    archived? = Keyword.get(opts, :archived, false)

    with {:ok, catalog} <- read(opts) do
      tasks =
        catalog["tasks"]
        |> Enum.filter(&(&1["project_id"] == project_id))
        |> Enum.filter(&(archived? or &1["status"] != "archived"))
        |> Enum.sort_by(& &1["updated_at_ms"], :desc)

      {:ok, tasks}
    end
  end

  defp transact(opts, fun) do
    path = Keyword.get(opts, :path, default_path(opts)) |> Path.expand()

    Alto.Storage.with_lock(path <> ".lock", fn ->
      with {:ok, catalog} <- read(Keyword.put(opts, :path, path)),
           {:ok, next, result} <- fun.(catalog),
           :ok <- persist(path, next) do
        {:ok, result}
      end
    end)
  end

  defp persist(path, catalog) do
    with :ok <- Alto.Storage.ensure_private_dir(Path.dirname(path), owned: true),
         {:ok, encoded} <- encode(catalog),
         :ok <- check_catalog_size(encoded),
         :ok <- AtomicWrite.write(path, encoded <> "\n", 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:catalog_write_failed, reason}}
    end
  end

  defp encode(catalog) do
    {:ok, JSON.encode!(catalog)}
  rescue
    error -> {:error, {:catalog_encode_failed, Exception.message(error)}}
  end

  defp decode(encoded, path) do
    case JSON.decode(encoded) do
      {:ok, %{"version" => @version, "projects" => projects, "tasks" => tasks} = catalog}
      when is_list(projects) and is_list(tasks) ->
        {:ok, catalog}

      {:ok, _other} ->
        {:error, {:catalog_invalid, path}}

      {:error, error} ->
        {:error, {:catalog_invalid_json, path, Exception.message(error)}}
    end
  end

  defp validate_changes(changes) when is_map(changes) do
    allowed =
      MapSet.new([
        "status",
        "backend",
        "session_id",
        "backend_thread_id",
        "next_step",
        "handoff_directory",
        "title"
      ])

    with {:ok, normalized} <- normalize_change_keys(changes) do
      unknown = normalized |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

      cond do
        unknown != [] ->
          {:error, {:invalid_task_fields, unknown}}

        Map.has_key?(normalized, "status") and normalized["status"] not in @statuses ->
          {:error, {:invalid_task_status, normalized["status"]}}

        Map.has_key?(normalized, "backend") and not valid_backend?(normalized["backend"]) ->
          {:error, {:invalid_task_backend, normalized["backend"]}}

        Enum.any?(
          ["session_id", "backend_thread_id", "next_step", "handoff_directory", "title"],
          fn key ->
            Map.has_key?(normalized, key) and
                not valid_state_field?(key, normalized[key])
          end
        ) ->
          {:error, :invalid_task_field_value}

        true ->
          {:ok, normalized}
      end
    end
  end

  defp validate_changes(other), do: {:error, {:invalid_task_changes, other}}

  defp empty, do: %{"version" => @version, "projects" => [], "tasks" => []}
  defp now_ms, do: System.system_time(:millisecond)

  defp normalize_change_keys(changes) do
    Enum.reduce_while(changes, {:ok, %{}}, fn
      {key, value}, {:ok, result} when is_atom(key) or is_binary(key) ->
        {:cont, {:ok, Map.put(result, to_string(key), value)}}

      {key, _value}, _result ->
        {:halt, {:error, {:invalid_task_field, key}}}
    end)
  end

  defp valid_backend?(value) when is_binary(value),
    do: Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, value)

  defp valid_backend?(_), do: false

  defp valid_state_field?(_key, nil), do: true
  defp valid_state_field?("backend", value), do: valid_backend?(value)
  defp valid_state_field?("title", value), do: bounded_binary?(value, @max_title_bytes)
  defp valid_state_field?(_key, value), do: bounded_binary?(value, @max_state_field_bytes)

  defp bounded_binary?(value, max),
    do: is_binary(value) and byte_size(value) <= max and String.valid?(value)

  defp valid_text?(value), do: is_binary(value) and value != "" and String.valid?(value)

  defp bounded_string(value, max) when is_binary(value) do
    if byte_size(value) <= max do
      value
    else
      value |> binary_part(0, max) |> trim_to_utf8()
    end
  end

  defp trim_to_utf8(value) do
    if String.valid?(value),
      do: value,
      else: trim_to_utf8(binary_part(value, 0, byte_size(value) - 1))
  end

  defp check_catalog_size(encoded) do
    if byte_size(encoded) <= @max_catalog_bytes do
      :ok
    else
      {:error, {:catalog_too_large, byte_size(encoded), @max_catalog_bytes}}
    end
  end

  defp id(prefix) do
    prefix <> "-" <> Base.encode32(:crypto.strong_rand_bytes(9), case: :lower, padding: false)
  end
end
