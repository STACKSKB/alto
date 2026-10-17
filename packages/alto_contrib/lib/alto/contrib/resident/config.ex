defmodule Alto.Contrib.Resident.Config do
  @moduledoc "Trusted service configuration; clients may select only registered profiles."

  @groups [
    child_runs: [
      max_retained: {128, 1..10_000},
      max_log_bytes: {64_000_000, 100_000..256_000_000},
      max_batch_bytes: {1_000_000, 64_000..8_000_000}
    ],
    workspaces: [
      max_retained: {128, 1..10_000},
      max_log_bytes: {64_000_000, 100_000..256_000_000}
    ],
    mailbox: [
      auto_compact: {true, :boolean},
      max_messages: {1_000, 1..10_000},
      max_completed: {10_000, 1..100_000},
      lease_ms: {30_000, 1_000..3_600_000},
      max_log_bytes: {64_000_000, 64_000..256_000_000}
    ],
    scheduling: [
      workers: {2, 1..16},
      max_attempts: {3, 1..32},
      poll_ms: {250, 10..60_000},
      run_timeout: {300_000, 100..86_400_000},
      max_model_requests: {64, 1..10_000},
      max_effects: {1_000, 1..100_000},
      max_pending: {100, 1..100},
      max_tasks: {1_000, 1..10_000}
    ]
  ]
  @options [
             workspace: [type: :string, required: true],
             state_dir: [type: :string],
             profiles: [type: {:map, :string, :any}, required: true],
             max_retained_events: [type: {:in, 1..100_000}, default: 1_000],
             runtime: [type: :atom, default: Alto.Contrib.Resident.Runtime.Alto]
           ] ++
             Enum.map(@groups, fn {field, fields} ->
               keys =
                 Enum.map(fields, fn {key, {default, bound}} ->
                   type = if bound == :boolean, do: :boolean, else: {:in, bound}
                   {key, [type: type, default: default]}
                 end)

               defaults = Enum.map(keys, fn {key, schema} -> {key, schema[:default]} end)
               {field, [type: :keyword_list, keys: keys, default: defaults]}
             end)
  @schema NimbleOptions.new!(@options)
  @enforce_keys [:workspace, :state_dir, :profiles]
  defstruct Enum.map(@options, fn {key, schema} -> {key, schema[:default]} end)

  @type t :: %__MODULE__{
          workspace: Path.t(),
          state_dir: Path.t(),
          profiles: map(),
          max_retained_events: pos_integer(),
          runtime: module(),
          child_runs: keyword(),
          workspaces: keyword(),
          mailbox: keyword(),
          scheduling: keyword()
        }

  def new(opts) when is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "service options must be a keyword list")

    settings = opts |> NimbleOptions.validate!(@schema) |> Map.new()
    workspace = Path.expand(settings.workspace)
    state_dir = Path.expand(Map.get(settings, :state_dir, default_state_dir()))
    profiles = settings.profiles
    runtime = settings.runtime

    unless is_atom(runtime) and Code.ensure_loaded?(runtime) and
             function_exported?(runtime, :children, 2),
           do: raise(ArgumentError, "runtime must implement Alto.Contrib.Resident.Runtime")

    unless File.dir?(workspace), do: raise(ArgumentError, "workspace must be a directory")

    unless is_map(profiles) and map_size(profiles) > 0 and
             Enum.all?(profiles, fn {name, config} ->
               is_binary(name) and byte_size(name) in 1..100 and
                 not String.starts_with?(name, "scheduled/") and Keyword.keyword?(config)
             end),
           do:
             raise(
               ArgumentError,
               "profiles must map names to Alto keyword options; scheduled/ is reserved"
             )

    struct!(__MODULE__, %{settings | workspace: workspace} |> Map.put(:state_dir, state_dir))
  rescue
    error in NimbleOptions.ValidationError -> raise ArgumentError, Exception.message(error)
  end

  def load(path) do
    case Code.eval_file(Path.expand(path)) do
      {%__MODULE__{} = config, _} ->
        {:ok, new(Map.to_list(Map.from_struct(config)))}

      {options, _} when is_list(options) ->
        {:ok, new(Keyword.fetch!(options, :resident))}

      _ ->
        {:error, :expected_resident_config}
    end
  rescue
    error -> {:error, {:config_load_failed, Exception.message(error)}}
  end

  def default_state_dir, do: Alto.Storage.dir("resident", nil)

  def socket_path(%__MODULE__{state_dir: dir}), do: Path.join(dir, "service.sock")

  def resolve(%__MODULE__{profiles: profiles}, name) do
    case Map.fetch(profiles, name) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, {:unknown_profile, name}}
    end
  end
end
