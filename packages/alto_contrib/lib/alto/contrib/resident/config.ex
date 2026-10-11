defmodule Alto.Contrib.Resident.Config do
  @moduledoc "Trusted service configuration; clients may select only registered profiles."

  @enforce_keys [:workspace, :state_dir, :profiles]
  defstruct [
    :workspace,
    :state_dir,
    :profiles,
    max_retained_events: 1_000,
    runtime: Alto.Contrib.Resident.Runtime.Alto,
    child_runs: [max_retained: 128, max_log_bytes: 64_000_000, max_batch_bytes: 1_000_000],
    workspaces: [max_retained: 128, max_log_bytes: 64_000_000],
    mailbox: [
      auto_compact: true,
      max_messages: 1_000,
      max_completed: 10_000,
      lease_ms: 30_000,
      max_log_bytes: 64_000_000
    ],
    scheduling: [
      workers: 2,
      max_attempts: 3,
      poll_ms: 250,
      run_timeout: 300_000,
      max_model_requests: 64,
      max_effects: 1_000,
      max_pending: 100,
      max_tasks: 1_000
    ]
  ]

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

    unknown =
      Keyword.keys(opts) --
        [
          :workspace,
          :state_dir,
          :profiles,
          :max_retained_events,
          :runtime,
          :scheduling,
          :mailbox,
          :child_runs,
          :workspaces
        ]

    if unknown != [], do: raise(ArgumentError, "unknown service options: #{inspect(unknown)}")
    workspace = opts |> Keyword.fetch!(:workspace) |> Path.expand()
    state_dir = opts |> Keyword.get(:state_dir, default_state_dir()) |> Path.expand()
    profiles = Keyword.fetch!(opts, :profiles)
    retention = Keyword.get(opts, :max_retained_events, 1_000)
    runtime = Keyword.get(opts, :runtime, Alto.Contrib.Resident.Runtime.Alto)
    scheduling = scheduling_options(Keyword.get(opts, :scheduling, []))
    mailbox = mailbox_options(Keyword.get(opts, :mailbox, []))
    workspaces = workspace_options(Keyword.get(opts, :workspaces, []))
    child_runs = child_run_options(Keyword.get(opts, :child_runs, []))

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

    unless is_integer(retention) and retention in 1..100_000,
      do: raise(ArgumentError, "max_retained_events must be between 1 and 100000")

    %__MODULE__{
      workspace: workspace,
      state_dir: state_dir,
      profiles: profiles,
      max_retained_events: retention,
      runtime: runtime,
      child_runs: child_runs,
      workspaces: workspaces,
      mailbox: mailbox,
      scheduling: scheduling
    }
  end

  defp child_run_options(options),
    do:
      bounded_options(:child_runs, options,
        max_retained: 1..10_000,
        max_log_bytes: 100_000..256_000_000,
        max_batch_bytes: 64_000..8_000_000
      )

  defp workspace_options(options),
    do:
      bounded_options(:workspaces, options,
        max_retained: 1..10_000,
        max_log_bytes: 100_000..256_000_000
      )

  defp mailbox_options(options),
    do:
      bounded_options(:mailbox, options,
        auto_compact: :boolean,
        max_messages: 1..10_000,
        max_completed: 1..100_000,
        lease_ms: 1_000..3_600_000,
        max_log_bytes: 64_000..256_000_000
      )

  defp scheduling_options(options),
    do:
      bounded_options(:scheduling, options,
        workers: 1..16,
        max_attempts: 1..32,
        poll_ms: 10..60_000,
        run_timeout: 100..86_400_000,
        max_model_requests: 1..10_000,
        max_effects: 1..100_000,
        max_pending: 1..100,
        max_tasks: 1..10_000
      )

  defp bounded_options(field, options, bounds) do
    defaults = Map.fetch!(__struct__(), field)

    schema =
      Enum.map(bounds, fn {key, bound} ->
        type = if bound == :boolean, do: :boolean, else: {:in, bound}
        {key, [type: type, default: Keyword.fetch!(defaults, key)]}
      end)

    case NimbleOptions.validate(options, schema) do
      {:ok, settings} -> settings
      {:error, error} -> raise ArgumentError, "invalid #{field}: #{Exception.message(error)}"
    end
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

  def default_state_dir do
    base = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join([base, "alto", "resident"])
  end

  def socket_path(%__MODULE__{state_dir: dir}), do: Path.join(dir, "service.sock")

  def resolve(%__MODULE__{profiles: profiles}, name) do
    case Map.fetch(profiles, name) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, {:unknown_profile, name}}
    end
  end
end
